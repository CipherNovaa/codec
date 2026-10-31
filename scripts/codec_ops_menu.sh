#!/bin/bash
# codec_ops_menu.sh — the codec ops panel. SUPER+SHIFT+M.
#
# Began as a DV-normalize launcher and became the place every long job is
# started and watched from, which the old layout still showed: one tool's verbs
# up top, everything added since in the order it was written.
#
# Now grouped by what you came to do — LOOK, RECLAIM, MEASURE, IMPORT — with a
# live bar readout in the header. Bars rather than percentages because a column
# of "86% 89% 97%" all reads the same at a glance; a bar shows which drive is
# the problem without comparing digits.

NORM="$HOME/Projects/codec/scripts/codec_dv_normalize.py"
RECONCILE="$HOME/Projects/codec/scripts/codec_reconcile.sh"
DUPES="$HOME/Projects/codec/scripts/codec_dupes.py"
SUBSTRIP="$HOME/Projects/codec/scripts/codec_substrip.py"
CROPWARM="$HOME/Projects/codec/scripts/codec_cropwarm.py"
JOBS="$HOME/Projects/codec/scripts/codec_jobs.sh"
DASH="$HOME/Projects/codec/scripts/codec_dash.py"
OCRSWEEP="$HOME/Projects/codec/scripts/codec_ocrsweep.py"
OCR_UNIT="codec-ocr-drain"
SVC="codec-dvnorm.service"
PY=/usr/bin/python3
WAL_COLORS="$HOME/.cache/wal/colors.json"

# pywal accent when it is on; codec's own steel when it is not. The author runs with
# pywal OFF by choice, so the fallback is the one that has to look right.
if command -v python3 >/dev/null && [ -f "$WAL_COLORS" ]; then
  ACCENT=$(python3 -c "import json;w=json.load(open('$WAL_COLORS'));print(w['colors']['color3'])" 2>/dev/null)
fi
[ -z "${ACCENT:-}" ] && ACCENT="#afaf5f"

# The live readout. Same bar code as the full panel — a header drawn by a second
# implementation is one that drifts out of step with the thing it heads.
# The pause entry carries its own state, so the menu shows what pressing it will
# DO rather than listing both directions.
PAUSE_LABEL=$("$HOME/Projects/codec/scripts/codec_pause.sh" label 2>/dev/null)
[ -z "$PAUSE_LABEL" ] && PAUSE_LABEL="󰏤  Pause"

# The PGS backlog sweep, as one row that says what pressing it does: start the
# drain, or — while it runs — show how far it has got.
if systemctl --user is-active --quiet "$OCR_UNIT"; then
  OCR_LABEL="󰊄  Subs — styling the PGS backlog (progress)"
else
  OCR_LABEL="󰊄  Subs — style the PGS backlog"
fi

HEADER=$("$PY" "$DASH" --rofi 52 2>/dev/null)
[ -z "$HEADER" ] && HEADER="<span color=\"#d75f5f\">status unavailable</span>"

MENU_THEME="
window   { width: 620px; border-radius: 0px; border: 2px; border-color: ${ACCENT}; }
mainbox  { padding: 8px; }
message  { padding: 10px 12px 12px 12px; border: 0px 0px 1px 0px; border-color: #3a3a3a; }
textbox  { text-color: #bcbcbc; }
inputbar { enabled: false; }
listview { lines: 13; columns: 1; spacing: 2px; padding: 6px 2px 2px 2px; scrollbar: false; }
element  { border-radius: 0px; padding: 7px 14px; }
element selected { background-color: ${ACCENT}; text-color: #101010; }
"

# Section rows are non-selectable dividers, so the list reads as groups rather
# than a flat pile of ten verbs.
choices=(
  "󰍹  Status — all jobs + disks"
  "󰑐  Watch live"
  "󰋊  Reclaim — duplicate titles"
  "󰤼  Reclaim — subtitle + audio tracks"
  "󰻂  DV — start / resume normalizing"
  "󰅖  DV — stop"
  "󰑓  DV — retry skipped titles"
  "󰊤  DV — details"
  "󰹑  Measure screen shapes (zoom)"
  "$OCR_LABEL"
  "󰋺  Import a new drive"
  "󰍉  Find + queue a torrent"
  "󰄜  Phone app — link + QR"
  "$PAUSE_LABEL"
)

chosen=$(printf '%s\n' "${choices[@]}" | rofi \
  -dmenu -i -no-custom -p "" \
  -markup -mesg "$HEADER" \
  -font "Iosevka Nerd Font 11" \
  -theme-str "$MENU_THEME")

[ -z "$chosen" ] && exit 0

toast() { command -v notify-send >/dev/null && notify-send -a "codec" "codec" "$1"; }
term()  { kitty --class codec-ops -e bash -lc "$1"; }
hold()  { term "$1; echo; echo '— press enter to close —'; read"; }

case "$chosen" in
  *"all jobs + disks"*)   hold "bash '$JOBS'" ;;
  *"Watch live"*)         term "bash '$JOBS' --watch" ;;

  # Report only, both of them. The remuxes are lossless and verified, but they
  # rewrite tens of gigabytes and can delete media — not something a menu should
  # start on one keystroke. Each prints the command that acts.
  *"duplicate titles"*)
    hold "'$PY' '$DUPES' --verify --deep; echo; \
          echo 'To act on these: $PY $DUPES --apply   (asks per title, moves to trash)'" ;;
  *"subtitle + audio"*)
    hold "'$PY' '$SUBSTRIP' --min-mb 20; echo; \
          echo 'To reclaim it: $PY $SUBSTRIP --apply --min-mb 20'" ;;

  *"start / resume"*)
    systemctl --user start "$SVC" && toast "normalizer started — pings you in Discord as titles finish" ;;
  *"DV — stop"*)
    systemctl --user stop "$SVC" && toast "normalizer stopped" ;;
  *"retry skipped"*)
    "$PY" "$NORM" --clear-skips >/dev/null 2>&1
    systemctl --user restart "$SVC"
    toast "re-queued skipped titles — normalizer restarted" ;;
  *"DV — details"*)
    hold "$PY '$NORM' --status; echo; echo 'All jobs at once:  bash $JOBS'" ;;

  # A full-film decode, minutes per film — it runs here rather than when someone
  # presses play.
  *"Measure screen shapes"*)
    hold "'$PY' '$CROPWARM' --status; echo; echo 'To measure the rest:  $PY $CROPWARM'" ;;
  # The import runs on a timer; this is for when you want it NOW rather than
  # within ten minutes. Safe to run at any time — it takes a lock, so it simply
  # reports and exits if the timer's run is already in flight.
  *"pull finished titles"*)
    hold "'$PY' '$HOME/Projects/codec/scripts/codec_qbit_import.py'" ;;
  # Searching for a magnet by hand on the laptop was the step that made adding
  # anything tedious; this is that fix applied to NEW titles rather than swaps.
  # Takes a pasted magnet too, since the five indexed trackers are general and
  # Western and simply cannot see a lot of foreign releases.
  # SIGSTOP, not stop-the-service: it keeps the work (a drain resumed mid-encode
  # rather than losing an hour) and it keeps nightwatch from helpfully restarting
  # a job it finds idle — which is how a drain once got started into a live watch
  # party. Downloads and imports keep running; they are network, not GPU.
  *"󰏤  Pause"*|*"󰐊  Resume"*)
    "$HOME/Projects/codec/scripts/codec_pause.sh" toggle ;;
  # In a TERMINAL, not rofi. rofi is right for picking a known item from a list
  # — which is what this menu is — but a search is a COMPARISON across five
  # attributes, and the ones that decide it (2160p, DV, HEVC, REMUX) sit at the
  # end of a release name, exactly what gets truncated to fit. hold() also gives
  # it room for a spinner, since the search takes tens of seconds.
  *"Find + queue a torrent"*)
    hold "'$PY' '$HOME/Projects/codec/scripts/codec_find.py'" ;;
  # OCR every bitmap (PGS) subtitle still waiting, so it plays as styled text
  # instead of the plain image. Hours of whole-film reads, so it runs as its own
  # transient unit (closing anything doesn't stop it; --collect clears the name
  # when it ends). It pauses itself while something casts, and the hub reads at
  # idle disk priority, so a local film keeps the drive.
  *"progress)"*)
    hold "'$PY' '$OCRSWEEP' --status; echo; journalctl --user -u $OCR_UNIT -n 15 --no-pager -o cat" ;;
  *"Subs — style the PGS backlog"*)
    if systemd-run --user --collect --unit="$OCR_UNIT" --nice=10 \
         "$PY" "$OCRSWEEP" --drain >/dev/null 2>&1; then
      toast "styling the PGS subtitle backlog — pauses for casts; progress in this panel"
    else
      toast "couldn't start the PGS sweep — is it already running?"
    fi ;;
  # The phone app (/r/<token>): your library + cast, installable from Chrome.
  # Its link is easy to lose, so it lives here — shown as a QR to scan and put
  # on the clipboard. Same link every time (rotate with codec_browse.py --new).
  *"Phone app"*)
    hold "'$PY' '$HOME/Projects/codec/scripts/codec_browse.py' --home --qr" ;;
  *"Import a new drive"*)
    term "echo '↻ scanning drives, importing new titles, refreshing art…'; '$RECONCILE'; echo; echo '— done. press enter to close —'; read" ;;
esac
