#!/bin/bash
# codec_screen.sh {input|power} — the OFA remote's INPUT and POWER keys, system-wide
# (bound in ~/.config/hypr/hyprland.lua, so they work whatever has focus, with
# codec closed, and with the tube asleep).
#
#   INPUT  MOVES codec between the desk monitor (DP-3) and the CRT (HDMI-A-1),
#          and never turns a screen off. A screen codec is going to must be lit,
#          so a sleeping one wakes first (and codec launches straight onto the
#          tube if it isn't running).
#   POWER  is the only key that turns a screen off: it sleeps / wakes the
#          screen codec is NOT on — in CRT mode the desk monitor, otherwise the
#          tube (standby without hyprlock).
#   (the author, 2026-10-14: "power for power and input for moving it" — INPUT used to
#   put the tube back to standby when it had woken it.)
#
# Neither key ever leaves no screen lit. Screens sleep through the kernel
# connector force-disconnect (crt-power / dp-power, passwordless via sudoers) —
# NEVER compositor dpms, which reshuffles the shared 2-CRTC pool and crashes the
# session. codec follows over D-Bus (org.codec.App MoveTo). Not bound `locked`,
# so neither key does anything over the lock screen.
set -u

CRT=HDMI-A-1
DESK=DP-3
RUN=${XDG_RUNTIME_DIR:-/tmp}
CODEC=$HOME/.local/bin/codec

say() { logger -t codec-screen "$*"; }

status() { local f; for f in /sys/class/drm/card*-"$1"/status; do cat "$f" 2>/dev/null; return; done; }
lit() { [ "$(status "$1")" = connected ]; }

[ -n "$(status "$CRT")" ] || exit 0   # no tube on this machine (the laptop)

# one press at a time: a second press while a screen is waking is dropped
exec 9>"$RUN/codec-screen.lock"
flock -n 9 || exit 0

power() {   # power <output> on|off
    local tool=dp-power
    [ "$1" = "$CRT" ] && tool=crt-power
    sudo -n "/usr/local/bin/$tool" "$2" 2>/dev/null || {
        say "$tool $2 failed"
        notify-send -a codec "codec" "couldn't switch $1 $2 ($tool)" 2>/dev/null
        return 1
    }
    say "$1 $2"
}

# Hyprland has the output (a woken connector takes a second or two to come up)
wait_mon() {
    local i
    for i in $(seq 40); do
        hyprctl monitors -j | jq -e --arg n "$1" 'any(.[]; .name == $n)' >/dev/null && return 0
        sleep 0.2
    done
    say "$1 never came up"
    return 1
}

# the output codec's window is on ("" = no codec window)
codec_on() {
    hyprctl clients -j | jq -r --argjson mons "$(hyprctl monitors -j)" '
        ([.[] | select(.class == "codec")][0].monitor) as $id
        | if $id == null then "" else ([$mons[] | select(.id == $id) | .name][0] // "") end'
}

# Bring codec's window to the front where it now lives. The tube going to
# standby hands its workspaces to the desk (one can take the desk's front), and an
# HDR film rebuilds codec's window on arrival — either left waybar over a
# half-placed codec. codec's Front focuses its own window and takes the pointer
# without showing it (a plain focus warps the arrow to mid-film and leaves it).
codec_front() {
    local pid
    pid=$(hyprctl clients -j | jq -r '[.[] | select(.class == "codec")][0].pid // empty')
    [ -n "$pid" ] || return 0
    busctl --user call org.codec.App /org/codec/App org.codec.App Front >/dev/null 2>&1 \
        || hyprctl dispatch "hl.dsp.focus({ window = \"pid:$pid\" })" >/dev/null
    sleep 0.5
    say "front: $(hyprctl clients -j | jq -c --arg p "$pid" '[.[] | select(.pid == ($p|tonumber))][0] | {ws: .workspace.id, mon: .monitor, fs: .fullscreen, size: .size}') active: $(hyprctl monitors -j | jq -c '[.[] | {(.name): .activeWorkspace.id}] | add')"
}

codec_move() {
    busctl --user call org.codec.App /org/codec/App org.codec.App MoveTo s "$1" >/dev/null 2>&1 && return 0
    say "codec didn't take MoveTo $1 (an older build?)"
    notify-send -a codec "codec" "restart codec to switch screens with INPUT" 2>/dev/null
    return 1
}

input() {
    local running=0 on
    pgrep -x codec >/dev/null && running=1
    on=$(codec_on)
    if [ "$running" = 1 ] && [ -z "$on" ]; then
        exit 0   # codec is still opening its window
    fi
    if [ "$on" = "$CRT" ]; then
        if ! lit "$DESK"; then power "$DESK" on && wait_mon "$DESK" || exit 1; fi
        codec_move "$DESK" || exit 1
        sleep 1
        codec_front
    else
        if ! lit "$CRT"; then power "$CRT" on && wait_mon "$CRT" || exit 1; fi
        if [ "$running" = 1 ]; then
            codec_move "$CRT" && sleep 1 && codec_front
        else
            # 9>&-: without it codec inherits the lock fd above and holds the
            # lock for as long as it runs — every later press was dropped
            setsid -f "$CODEC" --display "$CRT" 9>&- >/dev/null 2>&1
        fi
    fi
}

power_key() {
    local mine other
    mine=$(codec_on)
    if [ "$mine" = "$CRT" ]; then other=$DESK; else mine=$DESK; other=$CRT; fi
    if lit "$other"; then
        # the screen codec is on must stay lit; if it somehow isn't, light it instead
        if ! lit "$mine"; then power "$mine" on; exit 0; fi
        power "$other" off
    else
        power "$other" on
    fi
}

case "${1:-}" in
    input) input ;;
    power) power_key ;;
    *) echo "usage: codec_screen.sh {input|power}" >&2; exit 2 ;;
esac
