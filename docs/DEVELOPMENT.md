# Developing codec

How the tree fits together, how to build and test it, and the rules the UI
lives by. Start with **[STRUCTURE.md](STRUCTURE.md)** for where files go.

## The shape of it

codec is two halves that talk over pipes and HTTP:

| | Where | What |
|---|---|---|
| **The app** | `src/` (C++), `qml/` (QML) | The UI, local playback (libmpv), the library, resume and stats (SQLite), the queue. `src/appcontroller.*` is the controller every view talks to |
| **The workers** | `scripts/codec_cast.py`, `scripts/codec_yt.py` | Long-running Python children of the app, one JSON op per line on stdin, events back on stdout. The cast worker drives Google Cast; the YouTube worker reads YouTube |
| **The hub** | `scripts/codec_serve.py` | One HTTP server: library files, the cast lanes (HLS / DASH), the watch party and its web player, the Cast receiver page, pairing. A systemd user service when the library is shared |

Scripts are found at run time by `src/scriptpath.h`: `$CODEC_SCRIPTS`, then
`<bin>/../share/codec/scripts` (an install), then the source tree, then
`~/.local/bin`. Every script finds codec's data through `scripts/codec_paths.py`.

## Build

```sh
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
./build/codec
```

> [!IMPORTANT]
> **QML lives inside the binary** (Qt's resource system). Edit a `.qml` file and
> nothing changes until you rebuild. A **new** `qml/*.qml` file or
> `assets/mechui/` PNG must be added to its `qt_add_resources` list in
> `CMakeLists.txt`: the lists are explicit, and a missing file makes codec exit
> with `X is not a type` and an empty log.

QML errors go to the systemd journal, not the terminal. Run with
`QT_FORCE_STDERR_LOGGING=1` to see them.

The app is single-instance: a second launch forwards to the running one. After
a rebuild, quit the old one first.

## Seeing what you changed

**The screenshot harness** renders any view offscreen, without touching your
session (its own network namespace, a sandboxed config and database, a fake
compositor):

```sh
tools/shots/shots.sh dp3 home detail settings      # 2560×1440
tools/shots/shots.sh crt home                      # 1280×1024, CRT mode
NET=1 tools/shots/shots.sh dp3 ytpage              # YouTube views need the network
STAGE=movies EVAL="App.queueOpen = true" tools/shots/shots.sh dp3 custom
```

Output lands in `$XDG_RUNTIME_DIR/codec-shots/out/`. `CODEC_BIN=<other build>`
shoots a different binary.

**Under the hood** it's the app's own hooks: `CODEC_SHOT=<png>`,
`CODEC_SHOT_STAGE`, `CODEC_SHOT_DELAY`, `CODEC_SHOT_EVAL` (a QML expression),
`CODEC_SHOT_KEYS`.

**The frame meter**: `CODEC_FPS=1 ./build/codec` prints fps, render time and
CPU each second plus stall lines. An idle screen should read 0–2 fps.

**The Cast receiver without a TV**: `tools/rx-preview/preview.sh [index]`
renders the receiver from this checkout in headless Chromium at the TV's own
canvas, in every state (joining, playing, paused card, buffering, end, error),
with one library title's art ([its README](../tools/rx-preview/README.md)).

**Clips**: `tools/clip.sh <name> [seconds]` records codec's window (Hyprland)
and makes an mp4 for GitHub and an animated webp for the repo.

## Tests

```sh
for t in tests/test_*.py; do python3 "$t" || echo "FAILED: $t"; done
```

The tests cover the workers and the hub's logic offline: YouTube parsing and
codec's own lists, subtitle judging and re-timing, party seats, the Dolby
Vision timeline. There are no C++ or QML unit tests; the screenshot harness is
how the UI is checked.

## The UI's rules

These are what keep the pixel chrome crisp. Break one and something blurs or
drifts by a pixel.

- **Integer scale only.** Pixel art scales in whole steps (`mpx`); never a
  fractional factor on a plate, bar or icon.
- **The MGS faces live on a 16-px grid.** 16, 32, 48 … are crisp; anything else
  resamples. Headings use the Codec face, everything else the HUD face; dynamic
  text goes through `Theme.mgsSafe()`.
- **Align on the ink, not the box.** MGS text is placed by its glyphs' real
  baseline (`hudDrop`), and a badge's label is centred on its ink, then one
  screen pixel lower (`MechChip.opticalDy`).
- **`h` and `l` only ever move.** Never play, open or confirm.
- **An overlay's opening key closes it.**
- **No timed fades on selection.** Selection is instant (`DS.selDip`, `DS.selFade`).
- **Sounds**: views call `Sfx.play(cue)` where a change happens; one cue plays per event-loop turn. Never Qt Multimedia (it stalled start-up by 1.4 s).

`assets/mechui/hero/` is live-editable in a dev build: save a PNG there and
codec redraws it in about half a second, no rebuild.

## Casting

Four lanes, picked per title and per TV by the hub:

| Lane | Path |
|---|---|
| **Dolby Vision** | `codec_serve.py`: the film's profile 8.1 stream copied into DASH segments; the receiver plays it through Cast's own DASH stack |
| **HDR10 / HEVC** | NVENC transcode, PQ preserved, frames at their own size (padding a non-2160 frame corrupts HDR) |
| **SDR ladder** | NVENC with GPU tone-mapping (libplacebo), adaptive rungs |
| **Direct play** | The file as it is (the importer remuxes files faststart, `codec_faststart.py`) |

The **Cast receiver** is a page inside `codec_serve.py` (`_party_receiver()`),
exported as one static file by `scripts/codec_receiver_export.py`. It's
JavaScript inside a Python string: double every backslash, and run
`node --check` on the served page after any edit. See
[CAST-RECEIVER.md](CAST-RECEIVER.md).

FFmpeg is pinned to a static 8.x build (`scripts/setup_ffmpeg_static.sh`); 9.0
broke the zero-copy Vulkan → libplacebo path.

## The hub's lock

`codec_serve.py`'s private port answers loopback, a network marked trusted, a
paired device's key, a TV while it's being cast to, and party links. A request
from a foreign web origin gets media only. The **public** surface (for guests
and roaming) is token-scoped and keyed by **integer library index, never a
path**. Any new public route must follow that rule.

## Writing style

Comments say *why*, in plain sentences. Commit subjects for releases are
`vX.Y.Z — <a one-line name>`; the name is half the fun.

## More

[STRUCTURE.md](STRUCTURE.md) · [ASSET-MAP.md](ASSET-MAP.md) ·
[YOUTUBE.md](YOUTUBE.md) · [PARTY.md](PARTY.md) · [CHAT.md](CHAT.md) ·
[CAST-RECEIVER.md](CAST-RECEIVER.md) · [fonts](fonts/README.md)
