#!/usr/bin/env bash
# Bake button art from Aseprite source into the game PNGs, then codec's live
# dev-reload shows it (no rebuild). Writes ONLY the target family's 5 files —
# never the full import_mechui.py (which clobbers other hand-edited assets).
#
#   ./bake_button.sh 4            # pack family B4
#   ./bake_button.sh Continue 4   # Continue/ folder -> btn-4-*.png
#   ./bake_button.sh Play 4       # Play/ folder     -> btn-4-*.png
#
# Every master is the pack format: a folder of Idle/Hover/Pressed.aseprite,
# single layer, frame-based (Pressed = the 3 press frames) — same as btn-3.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
base="$root/source-assets/mecha/Aseprite/UI/Buttons/48x16"
out="$root/assets/mechui/buttons"
a="${1:?usage: bake_button.sh <family-number | Continue | Play> [family-number]}"
if [[ "$a" =~ ^[0-9]+$ ]]; then src="$base/B$a"; fam="$a"
else src="$base/$a"; fam="${2:?usage: bake_button.sh $a <family-number>}"; fi
[ -d "$src" ] || { echo "no source folder: $src" >&2; exit 1; }
aseprite -b -script-param srcDir="$src" -script-param outDir="$out" \
  -script-param family="$fam" -script "$root/tools/bake_button.lua"
echo "→ btn-$fam-{idle,hover,p0,p1,p2}.png  (from ${a})"
