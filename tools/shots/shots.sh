#!/usr/bin/env bash
# Offscreen screenshot set of codec's views, CRT (1280x1024, App.mode crt) and
# DP-3 (2560x1440) — built for the 2026-10-13 CRT layout pass.
#
#   tools/shots/shots.sh                 # every view, both modes
#   tools/shots/shots.sh crt home detail # one mode, some views
#   NET=1 tools/shots/shots.sh crt ytsubs # YouTube content needs the network
#   tools/shots/safe.py                  # mark the CRT's measured glass edge
#
# Output: $CODEC_SHOTS_DIR (default $XDG_RUNTIME_DIR/codec-shots)/out/<view>-<mode>.png
#
# Isolation (never touches the live codec instances or the real session):
#   - own network namespace (unshare -Un, loopback down): no hub /now, /rc
#     drain, cast discovery or YouTube — 127.0.0.1:8200 is unreachable
#   - bogus D-Bus address (no MPRIS / single-instance forwarding)
#   - fake hyprctl first in PATH (no window moves / monitor evals)
#   - sandboxed XDG_CONFIG_HOME, XDG_DATA_HOME (copy of config.json, the
#     watch DB via sqlite .backup, library cache), XDG_RUNTIME_DIR
#   - XDG_CACHE_HOME stays real: art + logo/probe caches are read; the only
#     writes are a per-run log file and regenerable caches
set -u
HERE="${CODEC_SHOTS_DIR:-${XDG_RUNTIME_DIR:-/tmp}/codec-shots}"   # renders + sandbox live here, not in the repo
mkdir -p "$HERE"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${CODEC_BIN:-$REPO/build/codec}"   # CODEC_BIN=<other build> shoots that one
OUT="$HERE/out"
SB="$HERE/sandbox"
mkdir -p "$OUT"

# ── sandbox (rebuilt each run so it mirrors today's config + DB) ────────────
rm -rf "$SB"
mkdir -p "$SB/config/codec" "$SB/data/codec" "$SB/run" "$SB/bin"
chmod 700 "$SB" "$SB/run"
cp "$HOME/.config/codec/config.json" "$SB/config/codec/"
# The STATS hero's CRT SHADER (settings.statsUiSel.heroCrt, a layer.effect)
# draws NOTHING in the offscreen renderer — the poster came out black. The
# sandbox copy turns it off (scanline overlay instead); the real config is untouched.
python3 - "$SB/config/codec/config.json" <<'PY'
import json, sys
p = sys.argv[1]; c = json.load(open(p)); s = c.get("settings", {})
if isinstance(s.get("statsUiSel"), str):
    u = json.loads(s["statsUiSel"]); u["heroCrt"] = "off"; s["statsUiSel"] = json.dumps(u)
# MECH='{"dial": value, ...}' tries GARAGE dials in the sandbox only
import os
if os.environ.get("MECH") and isinstance(s.get("mechUiSel"), str):
    u = json.loads(s["mechUiSel"]); u.update(json.loads(os.environ["MECH"])); s["mechUiSel"] = json.dumps(u)
json.dump(c, open(p, "w"))
PY
for f in tmdb-overrides.json audio_prefs.json; do
    [ -f "$HOME/.config/codec/$f" ] && cp "$HOME/.config/codec/$f" "$SB/config/codec/"
done
RD="$(python3 "$(dirname "$0")/../../scripts/codec_paths.py")"   # the real data folder, wherever it is now
sqlite3 "$RD/codec.db" ".backup '$SB/pristine.db'"
for f in library-cache.json party.json; do
    [ -f "$RD/$f" ] && cp "$RD/$f" "$SB/data/codec/"
done
[ -d "$RD/sprites" ] && cp -r "$RD/sprites" "$SB/data/codec/"
ln -s "$HOME/.local/share/fonts" "$SB/data/fonts"
printf '#!/bin/sh\n# shot sandbox: no compositor\n[ "$1" = monitors ] && echo "[]"\nexit 0\n' > "$SB/bin/hyprctl"
chmod +x "$SB/bin/hyprctl"

# ── the film every film-shaped view uses (clearlogo + poster in the library) ──
FILM_TITLE="Blade Runner 2049"
FILM="/mnt/Movies/Movies/Blade Runner 2049 2017 UHD  BluRay 2160p HDR10+ DV HEVC TrueHD Atmos 7.1 x265-E/Blade Runner 2049 DV.mkv"
MOCK="Engine.shotMockPlaying('$FILM_TITLE', 9840, 3725, '$FILM'); Engine.shotMockChapters([{title:'Opening',time:0},{title:'Sapper Morton',time:600},{title:'The Tree',time:1500},{title:'Joi',time:2700},{title:'Las Vegas',time:5400},{title:'Wallace',time:7200}])"

# shot <name> <mode crt|dp3> <env...>
if [ -n "${NET:-}" ]; then WRAP=env; else WRAP="unshare -Un --map-current-user"; fi
shot() {
    local name="$1" mode="$2"; shift 2
    local size modeenv png="$OUT/$name-$mode.png"
    if [ "$mode" = crt ]; then size=1280x1024; modeenv="CODEC_SHOT_MODE=crt"
    elif [ "$mode" = lap ]; then size=1920x1200; modeenv="CODEC_SHOT_MODE=hd"   # the laptop
    else size=2560x1440; modeenv="CODEC_SHOT_MODE=hd"; fi
    rm -f "$png"
    # every shot starts from the same watch state (a mock playback saves a
    # resume point, which then showed on the next shot's info page)
    cp "$SB/pristine.db" "$SB/data/codec/codec.db"
    rm -f "$SB/data/codec/codec.db-wal" "$SB/data/codec/codec.db-shm"
    # YTHOME=<dir>: the YouTube worker's home (its config's youtube.mode and
    # codec's own lists live under HOME) — a throwaway one for CODEC'S OWN shots
    env -i HOME="${YTHOME:-$HOME}" USER="$USER" LANG="${LANG:-C.UTF-8}" \
        PATH="$SB/bin:/usr/local/bin:/usr/bin:/bin" \
        XDG_CONFIG_HOME="$SB/config" XDG_DATA_HOME="$SB/data" \
        XDG_CACHE_HOME="$HOME/.cache" XDG_RUNTIME_DIR="$SB/run" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$SB/run/no-bus" \
        QT_QPA_PLATFORM=offscreen QT_ASSUME_STDERR_HAS_CONSOLE=1 \
        CODEC_SHOT="$png" CODEC_SHOT_SIZE="$size" "$modeenv" \
        "$@" \
        $WRAP timeout 40 "$BIN" \
        > "$OUT/$name-$mode.log" 2>&1
    if [ -s "$png" ]; then echo "ok   $name-$mode.png"
    else echo "FAIL $name-$mode.png (see $name-$mode.log)"; fi
}

view() {
    local v="$1" m="$2"
    case "$v" in
    home)     # wheel zone: j steps spot -> wheel (card + keycaps up)
        # the spotlight is shuffled per launch: pin it to the film so runs compare
        shot home "$m" CODEC_SHOT_STAGE=home CODEC_SHOT_KEYS=j CODEC_SHOT_KEYS_AT=1800 CODEC_SHOT_DELAY=4500 \
            CODEC_SHOT_EVAL="homeView.spotIdx = Math.max(0, homeView.spot.findIndex(s => s.path === '$FILM'))" \
            CODEC_SHOT_EVAL_DELAY=1500 ;;
    homerest) # the resting screen: spotlight zone, no card
        shot homerest "$m" CODEC_SHOT_STAGE=home CODEC_SHOT_DELAY=4500 \
            CODEC_SHOT_EVAL="homeView.spotIdx = Math.max(0, homeView.spot.findIndex(s => s.path === '$FILM'))" \
            CODEC_SHOT_EVAL_DELAY=1500 ;;
    homecw)   # CONTINUE deployed
        shot homecw "$m" CODEC_SHOT_STAGE=home CODEC_SHOT_DELAY=5000 \
            CODEC_SHOT_EVAL="homeView.spotIdx = Math.max(0, homeView.spot.findIndex(s => s.path === '$FILM')); homeView.zoneName = 'cw'" \
            CODEC_SHOT_EVAL_DELAY=1500 CODEC_SHOT_EVAL2="homeView.cwDeployed = true" CODEC_SHOT_EVAL2_DELAY=2500 ;;
    homecwf)  # CONTINUE focused, deck closed
        shot homecwf "$m" CODEC_SHOT_STAGE=home CODEC_SHOT_DELAY=4500 \
            CODEC_SHOT_EVAL="homeView.spotIdx = Math.max(0, homeView.spot.findIndex(s => s.path === '$FILM')); homeView.zoneName = 'cw'" \
            CODEC_SHOT_EVAL_DELAY=1500 ;;
    homecwp)  # CONTINUE open, the first poster selected (lifted)
        shot homecwp "$m" CODEC_SHOT_STAGE=home CODEC_SHOT_DELAY=5500 \
            CODEC_SHOT_EVAL="homeView.spotIdx = Math.max(0, homeView.spot.findIndex(s => s.path === '$FILM')); homeView.zoneName = 'cw'" \
            CODEC_SHOT_EVAL_DELAY=1500 CODEC_SHOT_EVAL2="homeView.cwDeployed = true; homeView.cwOnPosters = true" CODEC_SHOT_EVAL2_DELAY=2500 ;;
    attract)  # attract mode (idle wait shortened); ATTRACT_AT = ms after it starts
        # ATTRACT_PLOT=<min synopsis length> pins the loop to titles that long
        shot attract "$m" CODEC_SHOT_STAGE=home CODEC_ATTRACT_MS=1200 \
            CODEC_SHOT_DELAY=$(( 3000 + ${ATTRACT_AT:-6000} )) \
            ${ATTRACT_PLOT:+CODEC_SHOT_EVAL="attractView.playList(MediaLibrary.spotlight(400).filter(i => (i.plot || '').length >= $ATTRACT_PLOT))"} \
            ${ATTRACT_PLOT:+CODEC_SHOT_EVAL_DELAY=3000} ;;
    homeinfo) # the spotlight's mini info open
        shot homeinfo "$m" CODEC_SHOT_STAGE=home CODEC_SHOT_DELAY=5000 \
            CODEC_SHOT_EVAL="homeView.spotIdx = Math.max(0, homeView.spot.findIndex(s => s.path === '$FILM'))" \
            CODEC_SHOT_EVAL_DELAY=1500 CODEC_SHOT_EVAL2="homeView.spotInfoOpen = true" CODEC_SHOT_EVAL2_DELAY=2500 ;;
    ytrec|ythist) # FOR YOU / HISTORY — needs NET=1
        local tab; [ "$v" = ytrec ] && tab=rec || tab=history
        shot "$v" "$m" CODEC_SHOT_STAGE=youtube CODEC_SHOT_DELAY=${YT_DELAY:-16000} \
            CODEC_SHOT_EVAL="YouTube.openTab('$tab')" CODEC_SHOT_EVAL_DELAY=2500 ;;
    ytempty)  # a tab of codec's own lists with nothing in it — YTHOME=<a fresh home>
        shot ytempty "$m" CODEC_SHOT_STAGE=youtube CODEC_SHOT_DELAY=${YT_DELAY:-8000} \
            CODEC_SHOT_EVAL="YouTube.openTab('${TAB:-subs}')" CODEC_SHOT_EVAL_DELAY=3000 ;;
    ytmenu)   # SUBS, a video's hold-⏎ menu (SUBSCRIBE / UNSUBSCRIBE…) — needs NET=1
        shot ytmenu "$m" CODEC_SHOT_STAGE=youtube CODEC_SHOT_DELAY=${YT_DELAY:-14000} \
            CODEC_SHOT_EVAL="YouTube.openTab('${TAB:-subs}')" CODEC_SHOT_EVAL_DELAY=2500 \
            CODEC_SHOT_EVAL2="ytView.item.openContext()" CODEC_SHOT_EVAL2_DELAY=$(( ${YT_DELAY:-14000} - 1500 )) ;;
    ytnewpl)  # ADD TO PLAYLIST's picker, NEW PLAYLIST… being typed — YTHOME=<codec's-own home>
        shot ytnewpl "$m" CODEC_SHOT_STAGE=youtube CODEC_SHOT_DELAY=11000 \
            CODEC_SHOT_EVAL="YouTube.openTab('watchlater')" CODEC_SHOT_EVAL_DELAY=2500 \
            CODEC_SHOT_EVAL2="ytView.item.ctxItem = YouTube.itemAt(0); YouTube.fetchPlaylists()" \
            CODEC_SHOT_EVAL2_DELAY=7000 CODEC_SHOT_KEYS=ret,L,E,C,T,U,R,E,S CODEC_SHOT_KEYS_AT=9000 ;;
    ytpage)   # a video's own page — needs NET=1; VID=<video id> (default a
              # chaptered lecture), SEC=chapters|comments|related,
              # ZONE=actions|desc|tabs|body, KEYS=<keys pressed after>
        local vid="${VID:--2kZNL0uTXY}"
        shot ytpage "$m" CODEC_SHOT_STAGE=youtube CODEC_SHOT_DELAY=${YT_DELAY:-12000} \
            CODEC_SHOT_EVAL="ytView.item.openPage({videoId: '$vid', kind: 'video', title: '', uri: 'https://www.youtube.com/watch?v=$vid'})" \
            CODEC_SHOT_EVAL_DELAY=2500 \
            CODEC_SHOT_EVAL2="const pg = ytView.item.videoPage; pg.section = '${SEC:-related}'; pg.zone = '${ZONE:-actions}'" \
            CODEC_SHOT_EVAL2_DELAY=$(( ${YT_DELAY:-12000} - 4000 )) \
            ${KEYS:+CODEC_SHOT_KEYS=$KEYS} ${KEYS:+CODEC_SHOT_KEYS_AT=$(( ${YT_DELAY:-12000} - 3000 ))} ;;
    ytdrill)  # a channel or playlist opened, its header — needs NET=1;
              # URL=<channel or playlist link>, KEYS=<keys pressed after>,
              # EVAL2=<an expression run just before the shot>
        shot ytdrill "$m" CODEC_SHOT_STAGE=youtube CODEC_SHOT_DELAY=${YT_DELAY:-14000} \
            CODEC_SHOT_EVAL="YouTube.openUrl('${URL:-https://www.youtube.com/@openMathCamp}')" \
            CODEC_SHOT_EVAL_DELAY=2500 \
            ${KEYS:+CODEC_SHOT_KEYS=$KEYS} ${KEYS:+CODEC_SHOT_KEYS_AT=$(( ${YT_DELAY:-14000} - 3000 ))} \
            ${EVAL2:+CODEC_SHOT_EVAL2=$EVAL2} ${EVAL2:+CODEC_SHOT_EVAL2_DELAY=$(( ${YT_DELAY:-14000} - 900 ))} ;;
    ytsearch) # the search box open, its list under it — needs NET=1 for
              # suggestions; KEYS=<letters typed, then e.g. down,down>
        shot ytsearch "$m" CODEC_SHOT_STAGE=youtube CODEC_SHOT_DELAY=${YT_DELAY:-9000} \
            CODEC_SHOT_EVAL="App.youtubeSearchRequested()" CODEC_SHOT_EVAL_DELAY=3000 \
            ${KEYS:+CODEC_SHOT_KEYS=$KEYS} CODEC_SHOT_KEYS_AT=4000 ;;
    ytsubs)   # a video row selected (SUBS), description loaded — needs NET=1
        shot ytsubs "$m" CODEC_SHOT_STAGE=youtube CODEC_SHOT_DELAY=${YT_DELAY:-16000} \
            CODEC_SHOT_EVAL="YouTube.openTab('subs')" CODEC_SHOT_EVAL_DELAY=2500 \
            ${KEYS:+CODEC_SHOT_KEYS=$KEYS} ${KEYS:+CODEC_SHOT_KEYS_AT=$(( ${YT_DELAY:-16000} - ${KEYS_LEAD:-4000} ))} ;;
    library)  # SECTION=tv for the shows; SEL = a title's text to select (scrolls to it)
        shot library "$m" CODEC_SHOT_STAGE=${SECTION:-movies} CODEC_SHOT_DELAY=4500 \
            ${SEL:+CODEC_SHOT_EVAL="libView.item.selectRow('$SEL', '')"} ${SEL:+CODEC_SHOT_EVAL_DELAY=3000} ;;
    detail)   # DETAIL=<library path> to open another title
        shot detail "$m" CODEC_SHOT_STAGE=movies CODEC_SHOT_DELAY=5000 \
            CODEC_SHOT_EVAL="App.detailUri = '${DETAIL:-$FILM}'" CODEC_SHOT_EVAL_DELAY=1800 ;;
    detailshow) # a show's page (Berserk 1997)
        shot detailshow "$m" CODEC_SHOT_STAGE=movies CODEC_SHOT_DELAY=5000 \
            CODEC_SHOT_EVAL="App.detailUri = MediaLibrary.episodePaths('${SHOW:-Berserk}')[0]" CODEC_SHOT_EVAL_DELAY=1800 ;;
    youtube)  # offline unless NET=1 (then it reaches YouTube — and the hub)
        shot youtube "$m" CODEC_SHOT_STAGE=youtube CODEC_SHOT_DELAY=${YT_DELAY:-4500} ;;
    player)
        shot player "$m" CODEC_SHOT_STAGE=home CODEC_SHOT_DELAY=4500 \
            CODEC_SHOT_EVAL="$MOCK; App.toPlayer()" CODEC_SHOT_EVAL_DELAY=1800 ;;
    party)    # the w overlay over the playing film (no hub = no live room)
        shot party "$m" CODEC_SHOT_STAGE=home CODEC_SHOT_DELAY=5000 \
            CODEC_SHOT_EVAL="$MOCK; App.toPlayer()" CODEC_SHOT_EVAL_DELAY=1800 \
            CODEC_SHOT_EVAL2="App.partyOpen = true" CODEC_SHOT_EVAL2_DELAY=2800 ;;
    settings)
        shot settings "$m" CODEC_SHOT_STAGE=settings CODEC_SHOT_DELAY=4000 ;;
    ytset)    # Settings ▸ YOUTUBE (the account + the browsers found) — needs NET=1
        shot ytset "$m" CODEC_SHOT_STAGE=settings CODEC_SHOT_DELAY=${YT_DELAY:-7000} \
            CODEC_SHOT_EVAL="settingsView.item.openSection('youtube')" CODEC_SHOT_EVAL_DELAY=2500 ;;
    setdisp|setsubs|setcast|setremote)
        local sec; case "$v" in setdisp) sec=display;; setsubs) sec=subtitles;; setcast) sec=cast;; setremote) sec=remote;; esac
        shot "$v" "$m" CODEC_SHOT_STAGE=settings CODEC_SHOT_DELAY=4000 \
            CODEC_SHOT_EVAL="settingsView.item.section = '$sec'" CODEC_SHOT_EVAL_DELAY=2000 ;;
    help)     shot help "$m" CODEC_SHOT_STAGE=movies CODEC_SHOT_DELAY=3500 CODEC_SHOT_KEYS="?" ;;
    output)   # OUT_AT = ms after it opens (80 catches the rows fanning in)
              shot output "$m" CODEC_SHOT_STAGE=home CODEC_SHOT_DELAY=$(( 2000 + ${OUT_AT:-1500} )) CODEC_SHOT_EVAL="App.outputOpen = true" CODEC_SHOT_EVAL_DELAY=2000 ;;
    search)   shot search "$m" CODEC_SHOT_STAGE=home CODEC_SHOT_DELAY=3500 CODEC_SHOT_EVAL="App.searchOpen = true" CODEC_SHOT_EVAL_DELAY=2000 ;;
    custom)   # any stage + any expression: STAGE=<stage> EVAL=<js> [DELAY=ms] [NAME=out name]
        shot "${NAME:-custom}" "$m" CODEC_SHOT_STAGE=${STAGE:-home} CODEC_SHOT_DELAY=${DELAY:-5000} \
            CODEC_SHOT_EVAL="$EVAL" CODEC_SHOT_EVAL_DELAY=${EVAL_DELAY:-2000} ;;
    queue)    shot queue "$m" CODEC_SHOT_STAGE=movies CODEC_SHOT_DELAY=3500 CODEC_SHOT_KEYS="q" ;;
    setgrab)  # SUBTITLES with CAPTION SIZE grabbed and stepped twice
        shot setgrab "$m" CODEC_SHOT_STAGE=settings CODEC_SHOT_DELAY=4200 \
            CODEC_SHOT_EVAL="settingsView.item.section = 'subtitles'" CODEC_SHOT_EVAL_DELAY=2000 \
            CODEC_SHOT_EVAL2="settingsView.item.idx = 0; settingsView.item.activateRow(); settingsView.item.navSide(1); settingsView.item.navSide(1)" CODEC_SHOT_EVAL2_DELAY=3000 ;;
    showeps)  # an opened show's episode list; EP_AT = ms after it opens,
              # GUIDE = its guide road (roadmap|essentials|myth|reel), SEL = a row's title text
        shot showeps "$m" CODEC_SHOT_STAGE=movies CODEC_SHOT_DELAY=$(( 2400 + ${EP_AT:-1500} )) \
            CODEC_SHOT_EVAL="MediaLibrary.section = 'tv'; MediaLibrary.showFilter = '${SHOW:-The X-Files}'; MediaLibrary.guideMode = '${GUIDE:-}'" CODEC_SHOT_EVAL_DELAY=1500 \
            CODEC_SHOT_EVAL2="libView.item.selectRow('${SEL:-}', '')" CODEC_SHOT_EVAL2_DELAY=2400 ;;
    setswitch) # Settings switching PLAYBACK -> SUBTITLES; SW_AT = ms after
        shot setswitch "$m" CODEC_SHOT_STAGE=settings CODEC_SHOT_DELAY=$(( 2400 + ${SW_AT:-1500} )) \
            CODEC_SHOT_EVAL2="settingsView.item.switchSection(1)" CODEC_SHOT_EVAL2_DELAY=2400 ;;
    stats)
        shot stats "$m" CODEC_SHOT_STAGE=stats CODEC_SHOT_DELAY=7000 ;;
    *) echo "unknown view $v" ;;
    esac
}

ALL="home library detail youtube player party settings stats"
modes="crt dp3"; views="$ALL"
if [ $# -gt 0 ]; then
    case "$1" in crt|dp3|lap) modes="$1"; shift ;; esac
    [ $# -gt 0 ] && views="$*"
fi
for m in $modes; do
    for v in $views; do view "$v" "$m"; done
done

# ── montages ────────────────────────────────────────────────────────────────
for m in $modes; do
    files=()
    for v in $ALL; do [ -s "$OUT/$v-$m.png" ] && files+=("$OUT/$v-$m.png"); done
    [ ${#files[@]} -eq 0 ] && continue
    if [ "$m" = crt ]; then geo=640x512+6+6; else geo=640x360+6+6; fi
    magick montage -label '%t' "${files[@]}" -tile 4x -geometry "$geo" \
        -background '#222' -fill '#ddd' -pointsize 18 "$HERE/montage-$m.png" \
        && echo "montage-$m.png"
done
