# Contributing to codec

Thanks for looking. codec is a **developer preview**: it grew up on one
machine, one network and one television, and it's being made portable now.
That shapes what helps most.

## The most useful thing: try it somewhere new

Build it on your distro, point it at your folders, cast to your TV, and tell
us what happened. [Open an issue](../../issues/new/choose) with:

- your distro and version, your GPU and driver
- your television (make, model) if you cast
- what you did, what you expected, what you saw
- the log: run `QT_FORCE_STDERR_LOGGING=1 ./build/codec 2>&1 | tee codec.log`
  (QML errors otherwise go to the systemd journal: `journalctl --user -o cat | grep '\.qml:'`)

Screenshots help a lot. This is a visual app.

## Before writing code

Open an issue first for anything bigger than a fix, so we can agree on the
shape before you spend an evening on it. Then read
**[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)**: how the tree fits together,
the screenshot harness, and the UI's rules.

A few that matter most:

- **New QML files and mech-UI PNGs must be listed in `CMakeLists.txt`.** The
  resource lists are explicit; a missing file makes codec exit with
  `X is not a type`.
- **Pixel art scales in whole steps only**, and the MGS fonts live on a 16-px
  grid. If something looks a pixel off, it probably is.
- **`h` and `l` only ever move.** No key should surprise someone holding a remote.
- **The hub's public surface is keyed by integer library index, never a path.**
  Any new public route must keep that rule ([SECURITY.md](SECURITY.md)).
- **Show the change.** For UI work, attach before/after shots from
  `tools/shots/shots.sh`.
- **Run the tests**: `for t in tests/test_*.py; do python3 "$t" || echo "FAILED: $t"; done`

## Style

- Match the code around you: its naming, its comment density, its idiom.
- Comments say *why*, in plain sentences.
- Commit subjects are short and say what changed for the person using codec.

## Licence

codec is GPL-3.0. By contributing you agree your contribution is released
under the same licence.
