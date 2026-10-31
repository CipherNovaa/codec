#!/bin/bash
# codec_pause.sh — park every heavy codec job so the GPU and the disks are
# yours, then put them back exactly where they were.
#
# Why SIGSTOP rather than stopping the services:
#
#   1. It keeps the work. The Terminator was 1h into an nvenc run when it was
#      parked for a gaming session on 2026-09-12; SIGCONT resumed it mid-encode
#      rather than starting the hour again.
#   2. It keeps nightwatch off. The monitor restarts a drain it finds idle —
#      that is how a drain got started INTO a live watch party at 22:01 that
#      night. A stopped process still has a /proc entry, so nightwatch sees it
#      running and leaves it alone. Stopping the unit would invite it back.
#
# Downloads and imports are deliberately left running: they are network and
# disk, not GPU, and imports are what keep the torrent box from filling.
#
# Forgetting to resume is survivable — nightwatch reports parked jobs by name
# (check_suspended), so it shows up in the next heartbeat rather than silently
# never finishing.
set -u
STATE="$HOME/.cache/codec/paused.state"
JOBS="codec_dv_normalize.py codec_substrip.py codec_cropwarm.py"

toast() { command -v notify-send >/dev/null && notify-send -a "codec" "codec" "$1"; }

# Every PID of a job script, plus its descendants — the python parent spawns the
# ffmpeg/mkvmerge that actually holds the GPU, and stopping only the parent
# leaves the encoder running.
job_pids() {
  local out="" p kids
  for name in $JOBS; do
    for p in $(pgrep -f "[/ ]$name" 2>/dev/null); do
      [ "$p" = "$$" ] && continue
      out="$out $p"
      kids=$(pgrep -P "$p" 2>/dev/null | tr '\n' ' ')
      for k in $kids; do
        out="$out $k $(pgrep -P "$k" 2>/dev/null | tr '\n' ' ')"
      done
    done
  done
  echo "$out" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -un
}

state_of() { ps -o stat= -p "$1" 2>/dev/null | tr -d ' ' | cut -c1; }

# How long it has been held, for the menu label — "Resume" alone does not say
# whether you paused two minutes ago or forgot three hours back.
# A pause means "not right now, I am using the machine". A reboot ends that
# session AND kills the processes it was holding, so a flag that survives one
# leaves the pipeline half-inhibited: codec-dvnorm is `enabled` and starts at
# boot regardless, while nightwatch and the idle chain stay paused — with no
# held process left for check_suspended to report. Recording the boot id makes
# the flag self-expire instead.
boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null; }

is_paused() {
  [ -f "$STATE" ] || return 1
  local b
  b=$(awk '{print $2}' "$STATE" 2>/dev/null)
  if [ -n "$b" ] && [ "$b" != "$(boot_id)" ]; then
    rm -f "$STATE"                 # stale: set before a reboot
    return 1
  fi
  return 0
}

held_for() {
  is_paused || return 1
  local t now m
  t=$(awk '{print $1}' "$STATE" 2>/dev/null) || return 1
  now=$(date +%s); m=$(( (now - t) / 60 ))
  if   [ "$m" -lt 1  ]; then echo "just now"
  elif [ "$m" -lt 60 ]; then echo "${m}m ago"
  else echo "$(( m / 60 ))h $(( m % 60 ))m ago"
  fi
}

case "${1:-status}" in
  # One menu entry, not two. The label carries the state, so the panel shows
  # what pressing it will DO rather than offering both directions and leaving
  # you to remember which one applies.
  label)
    if h=$(held_for); then
      echo "󰐊  Resume — paused $h"
    else
      echo "󰏤  Pause"
    fi
    ;;
  toggle)
    if is_paused; then exec "$0" resume; else exec "$0" pause; fi
    ;;
  pause)
    n=0
    for p in $(job_pids); do
      [ "$(state_of "$p")" = "T" ] && continue
      kill -STOP "$p" 2>/dev/null && n=$((n+1))
    done
    printf '%s %s\n' "$(date +%s)" "$(boot_id)" > "$STATE"
    if [ "$n" -gt 0 ]; then
      toast "paused $n codec process(es) — GPU and disks are yours"
    else
      toast "nothing was running to pause"
    fi
    ;;
  resume)
    # Sweep by STATE, not by the list pause happened to build. A job spawns
    # children as it moves between stages, so one started after the pause — or
    # by a job that was itself resumed — can end up held with nothing looking
    # for it. Found exactly that: a dovi_tool left stopped across a test cycle
    # while every parent had already resumed.
    n=0
    for p in $(job_pids); do
      [ "$(state_of "$p")" = "T" ] || continue
      kill -CONT "$p" 2>/dev/null && n=$((n+1))
    done
    for p in $(pgrep -x ffmpeg 2>/dev/null; pgrep -x mkvmerge 2>/dev/null; \
               pgrep -x dovi_tool 2>/dev/null; pgrep -x mkvextract 2>/dev/null); do
      [ "$(state_of "$p")" = "T" ] || continue
      kill -CONT "$p" 2>/dev/null && n=$((n+1))
    done
    rm -f "$STATE"
    toast "resumed $n codec process(es)"
    ;;
  status)
    held=0 run=0
    for p in $(job_pids); do
      if [ "$(state_of "$p")" = "T" ]; then held=$((held+1)); else run=$((run+1)); fi
    done
    if [ "$held" -gt 0 ] || is_paused; then
      echo "PAUSED — $held process(es) held, $run still running"
      h=$(held_for) && echo "since $h"
    else
      echo "running — $run codec process(es)"
    fi
    ;;
  *)
    echo "usage: codec_pause.sh [pause|resume|status]" >&2; exit 2 ;;
esac
