# Mech-UI asset map

Where every piece of codec's pixel chrome lives, what draws it, and how to
change it. In a dev build **every mechui PNG on STATS and HOME hot-reloads**:
edit the file in `assets/mechui/`, save, and codec redraws it in about half a
second, no rebuild. `cmake --build build` bakes the current PNGs into the
binary for a release.

## The two kinds of thing you're recolouring

1. **PNG assets**: you draw or recolour the file. All live-reload. Listed below by group.
2. **Code colours**: Rectangles, gradients and ink tokens set in QML, not PNGs. You change the
   hex (or the in-editor ink dial). The big ones:
   - **Speedo / VFD "screen" background = `#05080e`**: `qml/StatsView.qml`, the dark screen
     the speedo rungs pop off, reused for the readout wells.
   - **Shadow ink = `#05080e`** (`shadowInk` in StatsView): text drop-shadows.
   - Per-element inks (title/stat/label/bar/graph…) come from the **ink dials** in the editor
     (ASSEMBLY/SYSTEM tabs) → the 24-colour hardware palette (`ink()` / `mechInks` in StatsView).
   - The **accent** and background glow: the `accent` dial and `Theme` tokens (`qml/Theme.qml`).
   - So a full dark theme = recolour the PNGs below + set the ink/accent dials + the
     `#05080e`-family hexes (already near-black).

## PNG groups (all LIVE) — folder → files → on-screen element → renderer

**The files now live in element-group subfolders under `assets/mechui/`** — open the folder for the
thing you want to draw. (The baked binary still sees them at their old flat path via a qrc alias, so
nothing in the code changed; live-edit finds a PNG in *any* folder by its filename.)

| Folder | Files | On screen | Rendered by |
|---|---|---|---|
| **hero/** (8) | panel-hero, hero-pill, hero-nameplate(-alt), hero-band-1/2/3, hero-bezel | STATS most-watched poster tile + nameplate | raw Image / MechSlice |
| **plates/** (16) | panel-card, panel-body, panel-sq1/2/3, panel-wide, panel-dlg, panel-frame, panel-hollow, panel-dlg-body, **panel-dlg-stats** (=cockpit), panel-console, panel-p2, panel-dlg-cap, chip, hdr-capsule | every readout WELL, row/title backing, the whole cockpit frame, the poster-header capsule | `MechPanel` (kind→plate) |
| **plates/yt-thumb-frame** (v1.47.1) | yt-thumb-frame.png — 32x32, hollow 9-slice, corners = 10 px each side, picture starts 5 px in | the FRAME around YouTube's big still (right side) | `MechSlice` in `YouTubeView.qml` (`plate.frameSlice` / `plate.frameIn`) |
| **buttons/** (30) | btn-{1..5}-{idle,hover,p0,p1,p2,press} | deck buttons, pill plate, play button, row plates | `MechButton` (family int) |
| **bars/** (12) | bar-frame, bar-frame-vfd, bar-fill(-l/-r), bar-seg, cell-empty/fill, bar4/5/6* | the TOP-WATCHED % meters + week meter | `MechBar` |
| **lasers/** (6) | laser-{a,b,c}-{core,muzzle} | bar "beam" style | `MechBar` (beam mode) |
| **chevron-tab/** (4) | chevron, stat-tab, stat-tab-hover, edge-slide* | row chevrons, the TOP WATCHED tab, row reveal edge | `MechSprite` / raw Image |
| **sep/** (2) | diamond, sep-diamond | nameplate separators | `MechSep` |
| **icons/** (15; used: 3) | icon-play, icon-plus, icon-x (+ 12 unused) | play glyph, +/x seps | raw Image / `MechSep` |
| **backdrops/** (4) | bg-city, bg-desert, bg-grass, bg-snow | HOME hangar background | raw Image (HomeView) |

\* `edge-slide` + the garage `icon-play` are two minor raw-Images not yet dev-wired — trivial to add
(same one-line pattern as `stat-tab`) if you want them live; say the word. `bar4/5/6` are unused.

### Not on STATS/HOME (don't bother recoloring for this):
- **mech-sprites/** `mech-{colour}-{1..4}` + `mech-shadow` (37) — MechEditor asset-browser only.
- **Dead/unused** (kept in their folders): `btn-*-press` (5), **sliders/** `slider-*` (3),
  `bars/bar4·bar6·bar5-*`, `plates/panel-console·panel-p2·panel-dlg-cap`, **fx/** `explosion·rocket`,
  12 unused `icons/icon-*`. Live if you edit them, but nothing on screen renders them.
- **Fonts** (`*.ttf`) stay flat at the `assets/mechui/` top level.

## The "4K HDR backing" you mentioned
There's **no dedicated 4K/HDR mechui backing** — in this codebase "hdr" means *header* (the poster
header row), not video HDR. The big background art actually on screen is:
- **HOME hangar backdrop** = `bg-{city,desert,grass,snow}.png` (mechui, **LIVE** — draw these).
- **STATS/HOME movie posters** = runtime library/TMDB art (`file://…`), not mechui — can't hot-reload
  as pngs; those come from your library.
- **HOME 3D globe** = `assets/globe3d/albedo.png` + `lights.png` (+ huge `src/*.jpg` Blue-Marble
  masters) — a separate pipeline, not mechui. Tell me if you want those live too.

## ✅ Folder layout — DONE
Every mechui PNG is now sorted into the group folders in the table above. The reorg was made safe by
a **qrc alias**: each file's source moved into its folder, but its *resource path stayed flat*
(`:/assets/mechui/<name>.png`), so QML and the shipped binary are byte-identical — only the on-disk
location changed. Live-edit resolves a PNG by filename in any folder, so you can even move a file
between groups and it still hot-reloads. If you ever add a brand-new PNG that the code doesn't already
reference, tell me so I can wire it in; recoloring existing files needs nothing from me.
