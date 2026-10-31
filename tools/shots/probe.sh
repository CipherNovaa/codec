#!/usr/bin/env bash
# probe.sh <stage> <eval-js> — one offscreen CRT run (SIZE/MODE override), printing
# console.log lines tagged PROBE. Reuses the sandbox shots.sh built (run it once first).
HERE="${CODEC_SHOTS_DIR:-${XDG_RUNTIME_DIR:-/tmp}/codec-shots}"; SB="$HERE/sandbox"
env -i HOME="$HOME" USER="$USER" LANG="${LANG:-C.UTF-8}" PATH="$SB/bin:/usr/local/bin:/usr/bin:/bin" \
  XDG_CONFIG_HOME="$SB/config" XDG_DATA_HOME="$SB/data" XDG_CACHE_HOME="$HOME/.cache" XDG_RUNTIME_DIR="$SB/run" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=$SB/run/no-bus" QT_QPA_PLATFORM=offscreen QT_ASSUME_STDERR_HAS_CONSOLE=1 \
  CODEC_SHOT="$HERE/out/probe.png" CODEC_SHOT_SIZE="${SIZE:-1280x1024}" CODEC_SHOT_MODE="${MODE:-crt}" \
  CODEC_SHOT_STAGE="$1" CODEC_SHOT_DELAY=${DELAY:-4000} CODEC_SHOT_EVAL="$2" CODEC_SHOT_EVAL_DELAY=3000 \
  unshare -Un --map-current-user timeout 30 "$(cd "$(dirname "$0")/../.." && pwd)/build/codec" 2>&1 | grep -E "PROBE|qml:.*[Ee]rror|TypeError|ReferenceError"
