# assets/ — SHIPPED (baked into the app)

These files are loaded by codec and **pinned by the build** (`CMakeLists.txt` +
`qrc:/assets/...` paths). To add/remove one you must edit CMakeLists too.

- `mechui/` — the mech-UI art. **Edit in place → hot-reloads live** in a dev
  build (Aseprite Ctrl-S updates codec in ~0.5s; no rebuild).
- `mechext/` — full pack mirror for the in-app browser (globbed).
- `globe3d/`, `foot3d/` — 3D globe + CRT-foot textures/shaders.

Raw source packs you curate FROM live in `../source-assets/`, not here.
See `../docs/STRUCTURE.md`.
