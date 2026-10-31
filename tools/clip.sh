#!/usr/bin/env bash
# Record codec's window into a clip ready for a README or a release page.
#
#   tools/clip.sh <name> [seconds] [countdown]   # Ctrl-C stops early
#
# Finds codec's window through Hyprland, counts down (3 s by default: time to
# get onto codec and pick up the remote), records it at 60 fps, then makes:
#   <name>.mkv   the master, near-lossless
#   <name>.mp4   1920 wide, H.264, for GitHub: drag it into the README editor
#                or a release and GitHub hosts it and plays it inline
#   <name>.webp  1280 wide, animated, small: plays inline from the repo itself
# into ~/Videos/codec-clips/.
#
# Needs wf-recorder and ffmpeg. Record the UI, not an HDR film: an HDR picture
# comes out with the wrong colours in a screen recording.
set -euo pipefail
name="${1:?usage: tools/clip.sh <name> [seconds]}"
secs="${2:-}"
wait="${3:-3}"
out="$HOME/Videos/codec-clips"; mkdir -p "$out"

geo=$(hyprctl clients -j | python3 -c '
import json, sys
for c in json.load(sys.stdin):
    if c.get("class") == "codec":
        (x, y), (w, h) = c["at"], c["size"]
        print(f"{x},{y} {w}x{h}"); break
')
[ -n "$geo" ] || { echo "codec isn't running (no window with class codec)"; exit 1; }
echo "recording codec at $geo"
for i in $(seq "$wait" -1 1); do printf '\r  %s ' "$i"; sleep 1; done; printf '\r  ● recording%s\n' "${secs:+ for ${secs}s}"

rec=(wf-recorder -g "$geo" -r 60 -c libx264 -p crf=12 -p preset=veryfast -f "$out/$name.mkv" -y)
if [ -n "$secs" ]; then timeout -s INT "$secs" "${rec[@]}" || true; else "${rec[@]}" || true; fi

echo "making the mp4 and the webp"
ffmpeg -loglevel error -y -i "$out/$name.mkv" \
    -vf "scale=1920:-2:flags=lanczos,format=yuv420p" -c:v libx264 -crf 20 -preset slow \
    -movflags +faststart -an "$out/$name.mp4"
ffmpeg -loglevel error -y -i "$out/$name.mkv" \
    -vf "fps=24,scale=1280:-2:flags=lanczos" -c:v libwebp -quality 80 -loop 0 -an "$out/$name.webp"
ls -lh "$out/$name".*
