#!/usr/bin/env bash
# Live button editing: watch the Aseprite masters and AUTO-BAKE on every save,
# so codec's live dev-reload shows the edit instantly — no manual bake, no
# rebuild. Run once in a terminal and leave it while you draw:
#     tools/watch_buttons.sh
# Then just Ctrl-S in Aseprite. Ctrl-C here to stop.
#
# Map: button master folder -> the game family it bakes into.
#   Continue -> family 4 (b4). CONTINUE and PLAY currently SHARE b4, so editing
#   Continue updates both. When PLAY gets its own art + family, add it here
#   (and wire the family — see the button-retexture notes).
#   YouTubeTab -> family 7 (b7): the YouTube tab plates, a copy of Continue.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
base="$root/source-assets/mecha/Aseprite/UI/Buttons/48x16"
out="$root/assets/mechui/buttons"
declare -A FAM=( [Continue]=4 [YouTubeTab]=7 )

bake(){ "$root/tools/bake_button.sh" "$1" "${FAM[$1]}" >/dev/null 2>&1 \
        && echo "  $(date +%T)  saved $1 -> btn-${FAM[$1]} (live in codec)"; }

dirs=()
for b in "${!FAM[@]}"; do
  if [ -d "$base/$b" ]; then dirs+=("$base/$b"); bake "$b"   # sync on start
  else echo "  (skip $b — no master folder yet)"; fi
done
[ ${#dirs[@]} -eq 0 ] && { echo "no master folders to watch"; exit 1; }

echo "> auto-bake watcher running — save in Aseprite, codec updates live. Ctrl-C to stop."
inotifywait -m -q -e close_write -e moved_to --format '%w%f' "${dirs[@]}" \
| while read -r f; do
    [[ "$f" == *.aseprite ]] || continue
    for b in "${!FAM[@]}"; do
      [[ "$f" == "$base/$b/"* ]] && bake "$b"
    done
  done
