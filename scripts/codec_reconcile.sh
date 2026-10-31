#!/usr/bin/env bash
# Fired by codec when a library scan (or an in-app delete) leaves the metadata
# out of step with disk: scrape art for new titles, PRUNE rows whose file is
# gone (guarded — aborts if a drive is unmounted), rebuild the manifest, and
# best-effort push to the laptop. The "reconcile with disk" fast path, so both
# added and removed files land everywhere without waiting for the nightly job.
#
# Deliberately the FAST SUBSET of codec_refresh.sh — no intro fingerprinting,
# subtitle sweep or vault sync (those stay on the nightly timer, where their
# cost is fine). This path's only job is "drop a file in, the poster shows up".
#
# CRITICAL ORDERING: the app rescans the instant THIS script exits, so the TMDB
# scrape (which puts art in the DB + cache) must be the ONLY thing gating our
# exit. The manifest rebuild + laptop rsync are for OTHER devices and used to
# run inline — a sleeping laptop's rsync timeouts (~45s) blocked the new poster
# from showing on THIS machine. They now run detached, off the UI critical path.
set -uo pipefail

log() { echo "[codec-reconcile] $(date '+%F %T') $*"; }

PY=/usr/bin/python3
# the scripts beside this one, wherever codec is installed or cloned
SCRIPTS="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# Household chores — the author's hub; opt-in anywhere else (config settings):
#   fileChores     the faststart guard + subtitle strip below REWRITE media files
#   satellitePush  an ssh host to rsync the manifest + art to (the author's: "laptop")
setting() { "$PY" -c 'import json,sys,os
try: v=json.load(open(os.path.expanduser("~/.config/codec/config.json"))).get("settings",{}).get(sys.argv[1],"")
except Exception: v=""
print("1" if v is True else ("" if v in (False,None) else v))' "$1"; }
FILE_CHORES="$(setting fileChores)"
PUSH_HOST="$(setting satellitePush)"
# wherever codec keeps its data (~/.local/share/codec, or the old myOS folder
# until the app has moved it) — scripts/codec_paths.py decides
MANIFEST="$("$PY" "$SCRIPTS/codec_paths.py")/remote-library.json"
BGLOG="$HOME/.cache/codec/reconcile-sync.log"
mkdir -p "$(dirname "$BGLOG")"

log "tmdb scrape + prune (incremental)"
"$PY" "$SCRIPTS/codec_tmdb.py" --prune || { log "tmdb scrape failed"; exit 1; }

# Clearlogos (the title art the detail/home views render) come from fanart.tv,
# NOT TMDB — the scrape above never touches them, which is why a fresh import
# shows its title as plain text. Fill any that are missing now, before we exit
# and the app rescans. Idempotent + negative-cached (titles fanart.tv has no
# logo for are marked and skipped), so this is instant once the library settles.
# Non-fatal: a logo miss must never fail the poster fast-path above.
log "fanart clearlogos (missing only)"
"$PY" "$SCRIPTS/codec_fanart_logos.py" || log "logo fetch had issues (non-fatal)"
# fanart.tv is MOVIES ONLY (its TV endpoint needs a TheTVDB id we don't store),
# so every show added after the one-off manual TMDB pass kept a plain-text title
# no matter how often UPDATE LIBRARY ran (Batman TAS, Edgerunners, X-Men '97,
# 2026-10-04). TMDB indexes logos for shows by tmdb_id; same idempotent
# fill-missing-only contract, and it backstops any movie fanart.tv lacks.
log "tmdb clearlogos (shows + fanart misses)"
"$PY" "$SCRIPTS/codec_tmdb_logos.py" || log "tmdb logo fetch had issues (non-fatal)"

# Budget / revenue / studio / country / language / writer for the detail page:
# the scrape above doesn't fetch them. One TMDB call per NEW title (rows are
# asked once), so a settled library costs a single SELECT.
log "detail facts (budget, studio, writer…) for new titles"
"$PY" "$SCRIPTS/codec_metadata_backfill.py" || log "detail facts had issues (non-fatal)"

# Bonus features of a new title (a film arriving with its Featurettes folder):
# frames + runtimes for the BONUS page, before the app's rescan reads them.
# Settled library = one directory walk; only a title WITH extras costs seconds.
log "bonus-feature thumbnails (new only)"
"$PY" "$SCRIPTS/codec_extras.py" || log "extras thumbnails had issues (non-fatal)"

# Art is now in the DB + cache. Surface it IMMEDIATELY by exiting; the manifest
# export + laptop push are for the satellite and must not sit on our exit. The
# subshell inherits these vars; redirecting its fds + disown lets us exit now
# while it finishes in the background (the nightly job is the backstop anyway).
log "art ready — detaching faststart guard + manifest export + laptop push"
{
    # Self-heal any newly-added non-faststart mp4 so it DIRECT-PLAYS on the TV
    # instead of freezing the cast (#233 — a compatible-codec mp4 with its moov
    # index at the end can't start on the Chromecast). The header check skips
    # already-faststart files instantly, so a settled library costs seconds; only
    # a genuinely new, direct-play-compatible non-faststart mp4 is LOSSLESSLY
    # re-muxed (-c copy, no bitrate change). Off the UI critical path on purpose:
    # a big remux must not sit on the "poster shows up" exit above.
    if [ -n "$FILE_CHORES" ]; then
    log "faststart guard (new direct-play mp4s)"
    "$PY" "$SCRIPTS/codec_faststart.py" || log "faststart guard had issues (non-fatal)"
    # Strip unwanted-language subtitle tracks from newly-arrived files. Same class
    # of operation as the faststart guard above — a LOSSLESS mkvmerge remux, no
    # re-encode, and the original is only replaced once the new file's VIDEO STREAM
    # hashes identically. This is the ROOT fix for the subtitle bloat measured on
    # 2026-09-09 (790 files, ~85 GB of non-English PGS by tag, ~52 GB real): strip
    # on import and it never accumulates again.
    #
    # --limit 2 is the important part. A stripped file has nothing left to drop, so
    # it is skipped for free ever after and this is self-terminating — but the FIRST
    # runs face a 124-file backlog of 40-60 GB remuxes. Bounding it keeps reconcile
    # from grinding for hours; the backlog drains a couple of titles per import, and
    # the rofi panel does the bulk pass when the author chooses to.
    log "subtitle strip (up to 2 files wasting >20MB)"
    "$PY" "$SCRIPTS/codec_substrip.py" --apply --min-mb 20 --limit 2 \
        || log "substrip had issues (non-fatal)"
    fi   # fileChores
    # The exporter aborts (exit 3) rather than write a partial manifest if a
    # drive is unmounted — then DON'T push, the laptop keeps its last good copy.
    if "$PY" "$SCRIPTS/export_library.py" --out "$MANIFEST"; then
        if [ -n "$PUSH_HOST" ]; then
            rsync -a --timeout=15 "$MANIFEST" \
                "$PUSH_HOST":.local/share/myOS/codec/remote-library.json 2>/dev/null \
              && rsync -a --timeout=30 "$HOME/.cache/codec/art/" \
                    "$PUSH_HOST":.cache/codec/art/ 2>/dev/null \
              && log "$PUSH_HOST synced" || log "$PUSH_HOST unreachable (nightly will catch up)"
        fi
    else
        log "export failed/aborted — leaving laptop untouched"
    fi
    log "background sync done"
} >>"$BGLOG" 2>&1 &
disown

log "done (art ready; manifest + laptop syncing in background)"
exit 0
