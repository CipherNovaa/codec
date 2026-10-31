# Where things live in codec

Every file is one of **three kinds**, in three places *on purpose*.
When unsure where something goes, find its kind below.

---

## 1. SHIPPED — baked into the app
The app loads these. **Pinned by the build** — moving one means editing
`CMakeLists.txt` + the `qrc:/...` path together. Don't drag these casually.

| Path | What |
|---|---|
| `assets/mechui/` | Curated mech-UI art (panels, buttons, bars, icons). Baked; edit + `cmake --build` to see changes. |
| **`assets/mechui/hero/`** | **The LIVE-EDITABLE set.** Edit a PNG here → codec updates in ~0.5s, no rebuild. **The folder is the signal: in `hero/` = live; elsewhere in `mechui/` = baked-only (for now).** |
| `assets/mechext/` | External art packs for the garage editor's asset browser (globbed; `manifest.js` lists them, empty in the public tree). |
| `assets/globe3d/` `assets/foot3d/` | 3D globe + CRT-foot textures/shaders (baked `*.png`/`*.frag`). |
| `qml/` | The UI (QML). |
| `src/` | The C++ engine. |
| `CMakeLists.txt` | The build — the manifest of what gets baked. |

## 2. SOURCE — raw material you curate *from*
The app never loads these directly. You edit/curate them into bucket 1.

| Path | What |
|---|---|
| `source-assets/` | Raw art packs and working files (git-ignored: bought packs can't be redistributed). The garage editor's importer browses here. |
| `source-assets/handmade/` | Hand-drawn working files. |
| `assets/globe3d/src/` | ~812 MB NASA masters. `.gitignore`'d + re-fetchable — safe to delete for disk. |

## 3. RUNTIME — written by codec while it runs
**These live OUTSIDE the project, and that's correct** (Linux convention — user
data never goes in the source tree). Don't pull them in.

| Path | What |
|---|---|
| `~/.local/share/codec/` | Watch DB, saved sprites, `now.json`, party/queue state, paired devices, YouTube lists. |
| `~/.config/codec/` | Settings (`config.json`), the mech-UI dial state. |

---

## The rest
- `_archive/` — corralled dead scratch + local backups. Git-ignored. Junk drawer.
- `assets/mechui/.bak/` — timestamped auto-backups of edited assets. Git-ignored.
- `scripts/` — the `codec_*` helper tools (library sync, cast, nav, self-check…).
- `docs/` — design notes.
- `build/` — compiler output. Git-ignored, regenerated.

## The dev asset loop (fast path)
Edit any PNG in **`assets/mechui/hero/`** in Aseprite → **Ctrl-S → codec updates
in ~0.5s**, no rebuild. Works because a dev build reads that folder live off disk
(`AppController::heroDevDir`, mtime-polled). A real `cmake --build` re-bakes it
for shipping. To make another asset live-editable, move it into `hero/` (and
update its `CMakeLists`/`qrc` path) — or ask and I'll wire more folders.
