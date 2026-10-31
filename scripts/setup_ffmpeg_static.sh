#!/usr/bin/env bash
# setup_ffmpeg_static.sh — ensure codec's static ffmpeg 8 is present & healthy.
#
# WHY THIS EXISTS
#   codec's HDR->SDR tone-map was written for ffmpeg 8's zero-copy Vulkan->libplacebo
#   path. ffmpeg 9.0.1 BREAKS it (compile-time EINVAL in vf_libplacebo when the system
#   libplacebo is API<365 AND the NVIDIA driver exposes synchronized queues), so a 4K
#   party silently falls back to a ~1.2x software path and can't hold live. The fix is a
#   fully-STATIC ffmpeg 8.1.2 at ~/deps/ffmpeg-n8.1-static (links only libm/libdl -> no
#   conflict with the system ffmpeg 9 / mpv / the codec player). codec_serve.py prefers
#   it via the FFMPEG/FFPROBE consts and now WARNS loudly at startup if it's missing.
#   This script is what that warning tells you to run. Revisit/retire the whole override
#   when Arch ships libplacebo API>=365 + an ffmpeg rebuilt against it (see the
#   project_codec_ffmpeg9_tonemap_fix memory).
#
# WHAT IT DOES (idempotent, self-healing, in priority order)
#   1. If the install is already present AND has libplacebo -> done.
#   2. Else restore from the local backup tarball if one exists (survives a BtbN URL
#      change — this is the exact build codec was validated against).
#   3. Else download the BtbN static n8.1 GPL build, extract, verify.
#   In all "present & healthy" cases it also makes the backup tarball if missing, so a
#   future restore never needs the network.
#
# Usage:  scripts/setup_ffmpeg_static.sh [--force] [--verify]
set -euo pipefail

DEST="$HOME/deps/ffmpeg-n8.1-static"
BIN="$DEST/bin"
BACKUP="$HOME/deps/ffmpeg-n8.1-static.tar.xz"
# BtbN publishes per-branch static builds under the rolling "latest" release. The 8.1
# branch is API-stable, so this URL tracks 8.1 point releases (all predate the ffmpeg-9
# libplacebo guard). If BtbN ever drops it, the local backup tarball is the fallback.
URL="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n8.1-latest-linux64-gpl-8.1.tar.xz"

log(){ printf '  %s\n' "$*"; }
die(){ printf '!! %s\n' "$*" >&2; exit 1; }

# healthy = ffmpeg runs, reports version 8, and has libplacebo (the whole point).
healthy(){
  [ -x "$BIN/ffmpeg" ] && [ -x "$BIN/ffprobe" ] || return 1
  "$BIN/ffmpeg" -hide_banner -version 2>/dev/null | head -1 | grep -q 'version n8\.' || return 1
  "$BIN/ffmpeg" -hide_banner -filters 2>/dev/null | grep -q libplacebo || return 1
  return 0
}

make_backup(){
  [ -f "$BACKUP" ] && return 0
  log "archiving the working build -> $BACKUP (offline restore point)"
  tar -C "$(dirname "$DEST")" -cJf "$BACKUP.tmp" "$(basename "$DEST")"
  mv "$BACKUP.tmp" "$BACKUP"
}

install_from_backup(){
  [ -f "$BACKUP" ] || return 1
  log "restoring from local backup $BACKUP"
  rm -rf "$DEST"
  tar -C "$(dirname "$DEST")" -xJf "$BACKUP"
  healthy
}

install_from_net(){
  command -v curl >/dev/null || die "curl not found — install curl or restore the backup manually"
  local tmp; tmp="$(mktemp -d)"
  log "downloading $URL"
  curl -fL --retry 3 -o "$tmp/ff.tar.xz" "$URL" \
    || die "download failed (BtbN URL may have moved). Restore from a known-good box's $BACKUP, or grab an n8.1 static GPL build from https://github.com/BtbN/FFmpeg-Builds/releases"
  log "extracting"
  tar -C "$tmp" -xJf "$tmp/ff.tar.xz"
  local top; top="$(find "$tmp" -maxdepth 1 -type d -name 'ffmpeg-*' | head -1)"
  [ -n "$top" ] || die "unexpected archive layout"
  rm -rf "$DEST"; mkdir -p "$DEST"
  cp -a "$top/." "$DEST/"
  rm -rf "$tmp"
  healthy
}

FORCE=0; VERIFY_ONLY=0
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    --verify) VERIFY_ONLY=1 ;;
    *) die "unknown arg: $a" ;;
  esac
done

echo "codec static ffmpeg 8 — ensure present & healthy"
mkdir -p "$HOME/deps"

if [ "$VERIFY_ONLY" = 1 ]; then
  if healthy; then
    log "OK: $("$BIN/ffmpeg" -hide_banner -version 2>/dev/null | head -1)"
    log "libplacebo: present"
    exit 0
  fi
  die "NOT healthy — run without --verify to install/restore"
fi

if [ "$FORCE" = 0 ] && healthy; then
  log "already healthy: $("$BIN/ffmpeg" -hide_banner -version 2>/dev/null | head -1)"
  make_backup
  log "done."
  exit 0
fi

log "install needed (force=$FORCE)"
if install_from_backup; then
  log "restored from backup, healthy."
elif install_from_net; then
  log "installed from network, healthy."
  make_backup
else
  die "could not produce a healthy install"
fi

log "final: $("$BIN/ffmpeg" -hide_banner -version 2>/dev/null | head -1)"
log "done. (codec_serve.py picks this up on its next restart)"
