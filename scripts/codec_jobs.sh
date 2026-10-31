#!/usr/bin/env bash
# codec_jobs.sh — one place to see every long-running codec job.
#
# There are several now (DV normalize, subtitle/audio strip) and they run for
# hours, so "is it still going, and how far?" needs answering without knowing
# which tool owns which log. Each tool already reports its own one-liner; this
# just gathers them.
#   --line   one compact line for the rofi header
#   (none)   full status, once
#   --watch  full status, redrawing until you quit
set -uo pipefail
PY=/usr/bin/python3
S="$HOME/Projects/codec/scripts"

line() {
  local dv st cw out=""
  dv=$("$PY" "$S/codec_dv_normalize.py" --status-line 2>/dev/null)
  st=$("$PY" "$S/codec_substrip.py"     --status-line 2>/dev/null)
  cw=$("$PY" "$S/codec_cropwarm.py"     --status-line 2>/dev/null)
  # Show a job only when it has something to say; three "idle" chips is noise.
  [[ -n "$dv" && "$dv" != *"idle"* ]] && out="$dv"
  [[ -n "$st" && "$st" != *"idle"* ]] && out="${out:+$out  ·  }$st"
  [[ -n "$cw" && "$cw" != *"idle"* ]] && out="${out:+$out  ·  }$cw"
  echo "${out:-all jobs idle}"
}

# A chain script can be waiting to START jobs. That is real pending work and it
# belongs at the TOP, before three "idle" blocks that would otherwise read as
# "nothing is happening tonight". Reads the chain's own state file and checks the
# recorded pid is alive, so a stale file from a killed chain says nothing.
chain() {
  local f="$HOME/.cache/codec/idle-chain.state" pid st on starts since
  [ -f "$f" ] || return 0
  pid=$(sed -n 's/^pid=//p' "$f"); st=$(sed -n 's/^state=//p' "$f")
  [ -n "$pid" ] && [ -d "/proc/$pid" ] || return 0
  [ "$st" = waiting ] || return 0
  on=$(sed -n 's/^waiting_on=//p' "$f")
  starts=$(sed -n 's/^starts=//p' "$f")
  since=$(sed -n 's/^since=//p' "$f")
  echo "  ⏳ QUEUED — waiting for $on, then starts: $starts"
  echo "     (chain pid $pid, waiting since $since)"
  echo
}

full() {
  # The dashboard first — bars for every job and every drive, which is what the
  # question "is it all still running" actually wants. The per-tool blocks stay
  # below it: they answer "what exactly did it do", and burying the overview
  # under three of them is what made this hard to read.
  "$PY" "$S/codec_dash.py"
  echo
  "$PY" "$S/codec_dv_normalize.py" --status 2>/dev/null | sed 's/^/  /'
  echo
  "$PY" "$S/codec_substrip.py" --status 2>/dev/null | sed 's/^/  /'
  echo
  "$PY" "$S/codec_cropwarm.py" --status 2>/dev/null | head -24 | sed 's/^/  /'
}

case "${1:-}" in
  --line)  line ;;
  --watch) exec "$PY" "$S/codec_dash.py" --watch ;;
  *)       full ;;
esac
