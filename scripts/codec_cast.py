#!/usr/bin/env python3
"""Codec cast worker — Chromecast/Google TV behind a JSON-lines protocol.

QProcess child of the app (same pattern as codec_yt.py): requests on stdin,
one reply per line, plus unsolicited events (device discovery, playback
status). pychromecast + zeroconf do the heavy lifting; the app stays clean
of the CASTv2 protocol.

Events pushed:
  {"event":"ready"}
  {"event":"device","id":u,"name":...,"model":...,"ip":...}
  {"event":"device_gone","id":u}
  {"event":"status","state":"PLAYING|PAUSED|BUFFERING|IDLE","position":s,
   "duration":s,"volume":0..1,"finished":bool}
  {"event":"tracks","audio":[{i,lang,title,codec}...],
   "subs":[{i,lang,title,codec,text}...],"aidx":N,"sub":-1|N,"mode":"fit"}
Requests:
  {"id":N,"op":"load","device":u,"uri":...,"title":...,"thumb":...,"position":s}
  {"id":N,"op":"pause"|"resume"|"stop"|"disconnect"}
  {"id":N,"op":"seek","position":s}
  {"id":N,"op":"volume","dir":"up"|"down"}
  {"id":N,"op":"set_audio","index":N}     # audio stream index (probe order)
  {"id":N,"op":"set_sub","index":-1|N}    # -1 = off
  {"id":N,"op":"add_sub","refresh":bool}  # a sidecar fetched WHILE casting: learn
                                          # track -2, show it, no lane restart
  {"id":N,"op":"sub_style"}               # push the cast caption style live
  {"id":N,"op":"screen_mode","mode":"fit"|"zoom"}
  {"id":N,"op":"rescan"}                  # fresh LAN search -> scan_done {found}
  {"id":N,"op":"add_ip","ip":"a.b.c.d"}   # ask one address -> device + add_ip_result

TRACK MODEL: text subtitles (srt/ass/mov_text) are extracted to WebVTT by
the owning server's /subs endpoint and SIDELOADED — the receiver renders
them, so on/off is instant (EDIT_TRACKS_INFO), and on direct streams the
clock is absolute so they stay aligned across seeks. Bitmap subs (PGS) and
any sub riding a transcode stream are BURNED IN by the lane instead (the
lane clock restarts at 0, which would desync a sideloaded track). Audio
selection rides the lane; screen-mode ZOOM does NOT — it's a CSS transform
on the receiver (per-film scale from film_crop), so it never re-encodes and
toggles with no rebuffer. Stretch is gone (zoom-only).

PORTABLE: media outside the hub tree is served by the worker itself on
:8205 (/file with Range + /transcode + /subs), allowlisted to loaded files
only. LAN IP is derived per-cast from the target device's address, so any
subnet works. ufw must allow 8205/tcp on machines that carry local media.
"""
import ipaddress
import json
import mimetypes
import os
import queue
import re
import socket as socketlib
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, unquote, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import codec_serve as hublib  # transcode_cmd / extract_vtt / NVENC probe
import codec_paths  # where codec's data lives (~/.local/share/codec)
codec_paths.install_hub_auth()   # a satellite's key rides every request to its hub

SERVE_PORT = 8200
SELF_PORT = 8205

# Audio the default receiver plays natively; everything else gets the lane.
SAFE_AUDIO = {"aac", "mp3", "opus", "vorbis", "flac"}
# Subtitle codecs that convert to WebVTT (everything else = bitmap -> burn).
TEXT_SUBS = {"subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text"}

_out_lock = threading.Lock()


def send(obj):
    if obj.get("event") != "status":
        dbg("evt " + json.dumps(obj)[:260])
    with _out_lock:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()


try:
    import pychromecast
    from pychromecast import quick_play
    from pychromecast.controllers.media import BaseMediaPlayer
    from pychromecast.controllers import BaseController
    import zeroconf as zeroconf_mod
except ImportError:
    send({"event": "fatal",
          "error": "pychromecast not installed — " + codec_paths.install_hint("pychromecast")})
    sys.exit(1)


# ── whose receiver runs on the television ───────────────────────────────────
# A direct cast used to go to Google's Default Media Receiver. It is a capable
# player and it is not ours: nothing on that screen can be styled, its idle
# plate is a grey system-font card, and there is no way to tell it anything.
# The watch-party receiver is a page THIS hub serves, so all of that is ours —
# and it is already registered, already on this TV, already the thing the phone
# remote casts to. The only reason `c` wasn't using it was that nobody had
# pointed it there.
#
# Measured on the Bravia, 2026-08-02: the receiver page is HTTPS (Google
# requires that of a registered receiver URL) while the media URLs built here
# are plain http on the LAN. That is mixed content, which modern Chromium
# blocks outright — and this set does not. Confirmed from the hub's own
# hls-access.log rather than from a status message: the TV fetched the master,
# the rendition and the segments, each request carrying Origin=https. So this
# costs nothing in delivery. Media still goes straight across the LAN; none of
# it has to leave the house through the Funnel and come back.
# the app's config — where Qt looks for it (XDG_CONFIG_HOME when set), so a
# sandboxed app and its worker read the SAME file
CFG_FILE = Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config")) / "codec/config.json"


def codec_receiver_app():
    """The registered App ID for codec's own receiver, or "" for none.

    Same value the watch party uses (codec_party_appid.py writes it). Without
    one there is nothing to launch and Google's receiver stays correct."""
    try:
        cfg = json.loads(CFG_FILE.read_text())
    except (OSError, ValueError):
        cfg = {}
    import codec_keys    # party.castAppId, else codec's own receiver
    app = codec_keys.cast_app_id(cfg)
    return app if len(app) == 8 and all(c in "0123456789ABCDEF" for c in app) else ""


class CodecReceiver(BaseMediaPlayer):
    """codec's receiver, driven exactly like the default one.

    Registered alongside the built-in media controller rather than replacing
    it — the socket client keeps a SET of handlers per namespace, so the
    watchdog's cast.media_controller.status keeps reporting throughout."""

    def __init__(self, app_id):
        super().__init__(supporting_app_id=app_id)


ZOOM_NAMESPACE = "urn:x-cast:com.codec.zoom"


class ZoomController(BaseController):
    """A one-way channel that pushes a screen-mode ZOOM SCALE to the receiver.

    Screen-mode zoom is applied on the TV as a CSS transform, not as a crop in
    the encoder — so toggling it must NOT restart the lane (that rebuffers). This
    controller lets the worker send the new scale over its own namespace and have
    the receiver re-scale the live picture instantly, mid-film, no reload."""

    def __init__(self):
        super().__init__(ZOOM_NAMESPACE)

    def set_zoom(self, scale, tl=None):
        """Push the scale, and the segment timeline when the film has one.

        `tl` is sent even as null so toggling from a variable-aspect film to a
        constant one clears the previous film's segments — a stale timeline would
        keep changing the zoom on a film that never changes shape."""
        try:
            self.send_message({"scale": float(scale or 1), "tl": tl})
            return True
        except Exception:
            return False


SUB_NAMESPACE = "urn:x-cast:com.codec.sub"


class SubController(BaseController):
    """One-way channel that pushes the active subtitle's VTT url (or null=off) to
    the receiver, which hand-renders it into its own #cap overlay. Lets a set_sub
    on a TEXT track land instantly (no lane restart) and keeps subs out of CAF's
    zoom-clipping caption layer."""

    def __init__(self):
        super().__init__(SUB_NAMESPACE)

    def set_sub(self, url):
        try:
            self.send_message({"url": url or None})
            return True
        except Exception:
            return False

    def set_style(self, style):
        """The caption face (font / colour / size / box) — live, no reload."""
        try:
            self.send_message({"style": dict(style or {})})
            return True
        except Exception:
            return False


TOAST_NAMESPACE = "urn:x-cast:com.codec.toast"


class ToastController(BaseController):
    """One-way channel that flashes a short action toast on the receiver — the
    TV-side echo of the app's OsdToast. A remote press that changes the subtitle,
    audio track or screen mode confirms itself on screen ("SUBTITLES · ENG",
    "AUDIO · ENG 5.1", "ZOOM") so the button never feels dead, styled as a codec
    badge plate rather than a web toast."""

    def __init__(self):
        super().__init__(TOAST_NAMESPACE)

    def show(self, text, ms=None, hide=False, prompt=False):
        """`ms` holds the toast past the default 1.6 s flash; `hide` takes a
        held one down early (the receiver ignores both on older pages)."""
        msg = {"text": str(text or "")}
        if ms:
            msg["ms"] = int(ms)
        if hide:
            msg["hide"] = True
        if prompt:
            msg["prompt"] = True   # the TV remote's OK/Back answer it while held
        try:
            self.send_message(msg)
            return True
        except Exception:
            return False


_RX_REFUSED = {}          # uid -> time.time() after which we retry the custom receiver
RX_BLOCK_TTL = 20.0       # seconds a refusal suppresses the custom receiver.
# Short on PURPOSE: a transient title-SWITCH race ("loaded nothing" while the
# receiver is mid-teardown of the previous film) must NOT downgrade every later
# cast to Google's default receiver for minutes. 20s clears one hiccup; a truly
# lapsed App ID just re-trips next cast (cheap) instead of poisoning the session.
RX_LAUNCH_TRIES = 2       # custom-receiver launch attempts before falling back
RX_RETRY_GAP = 1.5        # seconds between attempts (lets a transient CANCELLED clear)
_CARD_CACHE = {}
_SHOW_CACHE = {}


def _show_entry(name):
    """The kind:show manifest entry for a show name (cached). Episode cast cards
    borrow the show's portrait poster + rating + genres from it, since an episode
    carries an episode still and usually no rating/genres of its own."""
    if not name:
        return None
    if name in _SHOW_CACHE:
        return _SHOW_CACHE[name]
    found = None
    try:
        for e in hublib._browse_entries():
            if e.get("kind") == "show" and (e.get("show") or e.get("title")) == name:
                found = e
                break
    except Exception:
        found = None
    _SHOW_CACHE[name] = found
    return found


def _library_rel(p):
    """A source — path OR url — as one path relative to the library root.

    ⚠ Both forms are in play and they do not look alike. A session's `src` is
    the URL form for anything in the hub's own tree (the lane wants a URL the
    hub can fold back onto its root), a filesystem path only for portable
    media outside it — while the manifest stores URLs. Matching a `src`
    against a manifest entry with realpath() therefore compared a URL to a
    path and never once agreed, which is exactly how the year and the artwork
    reached the television as nothing at all."""
    if not p:
        return ""
    if "://" in p:
        p = unquote(urlparse(p).path)
    elif codec_paths.hub_rel(p):
        p = codec_paths.hub_rel(p)
    return os.path.normpath("/" + p.lstrip("/"))


def library_card(src):
    """Year and artwork for a library file, out of the hub's own manifest.

    The card on the television is drawn by codec now, so it wants what the
    app's detail page has rather than what the cast protocol carries — a year
    to sit beside the title, and a piece of art to fill the frame while a film
    is paused. Both are already in the manifest; nothing new is fetched.

    A file that isn't in this library — a stray path, a YouTube video, someone
    else's hub — simply gets no card, and the overlay falls back to the
    wordmark alone. That is the same thing it did before, so nothing that
    worked stops working."""
    if not src:
        return {}
    key = _library_rel(src)
    if not key:
        return {}
    if key in _CARD_CACHE:
        return _CARD_CACHE[key]
    out = {}
    ep = None
    try:
        for e in hublib._browse_entries():
            u = e.get("url") or ""
            if not u or _library_rel(u) != key:
                continue
            # "2006 · 1080p" / "2002 · 4K · HDR" — the year goes beside the
            # title, and everything after it is what the FILE is, which is
            # exactly what a panel about the file should say. Taken from the
            # manifest rather than re-derived: this is the same string the
            # library and the detail page show, so the television cannot
            # disagree with the app about what a film is.
            parts = [p.strip() for p in (e.get("subtitle") or "").split("·")
                     if p.strip()]
            if parts and len(parts[0]) == 4 and parts[0].isdigit():
                out["year"] = parts[0]
                parts = parts[1:]
            if parts:
                out["quality"] = parts
            # The truthful probe-derived badge set (4K/DV/HDR10/ATMOS/7.1…), the
            # SAME array the library grid's MechChips use — so the TV overlay
            # shows exactly what the app does, from the STREAM, never the filename
            # or the subtitle (which drops DV+ATMOS). renderBadges prefers this
            # over string-matching the meta line.
            out["flags"] = e.get("flags") or []
            # The POSTER, not the backdrop. The paused frame is still on the
            # screen and is the only backdrop this needs; what it hasn't got
            # is the thing the library shows you.
            if e.get("poster"):
                # The manifest stores the poster as a full /art?f=<file> URL
                # (export_library's art_url()). card_into() re-wraps whatever is
                # here through the CURRENT base (so it resolves over the Funnel
                # when roaming, not just the hard-coded LAN IP) — so reduce it to
                # the bare art filename. Pull the f= param out of an art URL, else
                # basename a path. ⚠ Was os.path.basename() ALONE, which turned
                # ".../art?f=HASH.jpg" into "art?f=HASH.jpg" and double-wrapped to
                # ".../art?f=art%3Ff%3DHASH.jpg" → 404 → the paused poster never
                # showed (onerror hides #ipwrap).
                _p = e["poster"]
                if "art?f=" in _p:
                    _p = unquote(parse_qs(urlparse(_p).query).get("f", [""])[0]) or _p
                out["poster"] = os.path.basename(_p)
            # The title logo and the backdrop, for the receiver's dock and
            # the paused card's hero (both art names; card_into wraps them
            # through the current base like the poster).
            for _k, _f in (("logo", "clearlogo"), ("backdrop", "fanart")):
                _u = e.get(_f) or ""
                if _u:
                    if "art?f=" in _u:
                        _u = unquote(parse_qs(urlparse(_u).query).get("f", [""])[0]) or _u
                    out[_k] = os.path.basename(_u)
            # the detail page's money line, as numbers (the short $5.5M form
            # above stays for the old overlay)
            try:
                out["revenueN"] = int(e.get("revenue") or 0)
                out["budgetN"] = int(e.get("budget") or 0)
            except (TypeError, ValueError):
                pass
            if e.get("director"):
                out["dir"] = e["director"]
            if e.get("writer"):
                out["writer"] = e["writer"]
            try:
                r = int(e.get("runtimeMin") or 0)
                if r:
                    out["run"] = (f"{r // 60}h {r % 60}m" if r >= 60
                                  else f"{r}m")
            except (TypeError, ValueError):
                pass
            try:
                rating = float(e.get("rating") or 0)
                if rating:
                    out["rate"] = f"{rating:.1f}"
                    out["rating"] = round(rating, 1)   # numeric 0-10 → star row on the overlay
            except (TypeError, ValueError):
                pass
            # Two genres, not five. A list long enough to wrap stops being a
            # fact about the film and becomes a paragraph.
            g = [x.strip() for x in (e.get("genres") or "").split("/") if x.strip()]
            if g:
                out["gen"] = ", ".join(g[:2])
            # Budget — a fact about a FILM (TMDB tracks it per movie; TV shows carry
            # 0, so episodes never get one). Abbreviated for a glanceable TV card.
            try:
                _bud = int(e.get("budget") or 0)
                if _bud >= 1000000:
                    out["budget"] = f"${_bud / 1000000:.1f}M".replace(".0M", "M")
                elif _bud >= 1000:
                    out["budget"] = f"${_bud // 1000}K"
            except (TypeError, ValueError):
                pass
            if e.get("kind") == "episode":
                ep = e
            break
    except Exception:
        out = {}
    # An episode carries an episode STILL (not a poster) and usually no rating or
    # genres — the paused card wants the SHOW's portrait poster + the show's
    # rating/genres, and a title that reads  SHOW "Episode name"  (the SxxExx code
    # already rides the top-left readout). Borrow them from the kind:show entry.
    # (Not the director: a show's "director" is its creator, wrong per-episode.)
    if ep is not None:
        _t = ep.get("title") or ""
        _j = _t.find(" · ")
        out["show"] = ep.get("show") or ""
        out["episode"] = _t[_j + 3:] if _j >= 0 else _t
        _show = _show_entry(ep.get("show") or "")
        if _show:
            if _show.get("poster"):
                _sp = _show["poster"]
                if "art?f=" in _sp:
                    _sp = unquote(parse_qs(urlparse(_sp).query).get("f", [""])[0]) or _sp
                out["poster"] = os.path.basename(_sp)
            if "rate" not in out:
                try:
                    _rr = float(_show.get("rating") or 0)
                    if _rr:
                        out["rate"] = f"{_rr:.1f}"
                        out["rating"] = round(_rr, 1)
                except (TypeError, ValueError):
                    pass
            if "gen" not in out:
                _gg = [x.strip() for x in (_show.get("genres") or "").split("/") if x.strip()]
                if _gg:
                    out["gen"] = ", ".join(_gg[:2])
    _CARD_CACHE[key] = out
    return out


# ffprobe's names are not the names on a box. Nothing here is invented — it is
# the same codec, spelled the way the release is.
_ACODEC = {"truehd": "TrueHD", "dts": "DTS", "eac3": "E-AC3", "ac3": "AC3",
           "aac": "AAC", "flac": "FLAC", "opus": "Opus", "mp3": "MP3",
           "vorbis": "Vorbis", "pcm_s16le": "PCM", "pcm_s24le": "PCM"}
_CHANNELS = {1: "Mono", 2: "Stereo", 3: "2.1", 6: "5.1", 7: "6.1", 8: "7.1"}


def audio_line(audio):
    """"TrueHD 7.1" — what the film's own soundtrack is.

    Deliberately the SOURCE track and not what the cast lane ends up sending:
    a 7.1 TrueHD film is a 7.1 TrueHD film even while this television is being
    handed stereo AAC, because the panel is describing the film, not the
    plumbing. ffprobe already returns channels on every audio stream, so this
    costs nothing beyond the probe that has always run."""
    if not audio:
        return ""
    a = audio[0]
    codec = (a.get("codec") or "").lower()
    name = _ACODEC.get(codec, codec.upper())
    ch = _CHANNELS.get(a.get("channels") or 0, "")
    return " ".join(x for x in (name, ch) if x)


def _pref_audio_lang():
    """The viewer's preferred audio language (ISO code), default English. Set in
    ~/.config/codec/config.json as {"audio": {"language": "jpn"}} — a Settings UI
    writes it; absent (or unreadable) = 'eng'."""
    try:
        cfg = json.loads(CFG_FILE.read_text())
        return ((cfg.get("audio") or {}).get("language") or "eng").strip().lower()
    except (OSError, ValueError, AttributeError):
        return "eng"


def _lang_matches(track_lang, pref):
    """ISO-code match tolerant of the 2- vs 3-letter forms (en/eng, ja/jpn)."""
    l = (track_lang or "").strip().lower()
    if not l or not pref:
        return False
    return l == pref or (len(l) >= 2 and len(pref) >= 2 and l[:2] == pref[:2])


# Rough soundtrack-quality order from the codec NAME alone (ffprobe reports
# DTS-HD MA simply as "dts", so this is coarse — channels do the heavy lifting).
_ACODEC_RANK = {"truehd": 6, "flac": 6, "dts": 5, "eac3": 4, "ac3": 3,
                "opus": 2, "aac": 2, "mp3": 1}


def _best_quality(tracks, pref):
    """Of a set of tracks, the best soundtrack: most channels, then richer codec,
    then the preferred language as a tiebreak, then probe order."""
    return min(tracks, key=lambda t: (
        -(t.get("channels") or 0),
        -_ACODEC_RANK.get((t.get("codec") or "").lower(), 0),
        0 if _lang_matches(t.get("lang"), pref) else 1,
        t.get("i", 0))).get("i", 0)


def _default_audio(audio, pref=None):
    """The FIRST-TIME default track for a film nobody has set a preference on:
    the language the release SHIPS as default (its original language as
    intended) — among the tracks flagged `default`, the best-quality one. So a
    foreign film plays in its own language (The Raid -> Indonesian), a Hollywood
    film plays English, and anime starts on the Japanese track. If nothing is
    flagged, best quality overall with the preferred language breaking the tie.
    Per-film memory (see _choose_audio) overrides this once the viewer picks."""
    if not audio:
        return 0
    pref = pref if pref is not None else _pref_audio_lang()
    flagged = [t for t in audio if t.get("default")]
    return _best_quality(flagged or audio, pref)


# Per-film audio-language memory: no single global rule fits both "The Raid in
# the original" and "anime in the English dub", so we remember the LANGUAGE the
# viewer last chose for each film and replay it. Language (not track index) so it
# survives a re-encode/replacement that renumbers the streams.
_AUDIO_MEM_FILE = Path.home() / ".config/codec/audio_prefs.json"


def _audio_mem():
    try:
        return json.loads(_AUDIO_MEM_FILE.read_text())
    except (OSError, ValueError):
        return {}


def _remember_audio_lang(film_key, lang):
    lang = (lang or "").strip().lower()
    if not film_key or not lang:
        return
    mem = _audio_mem()
    if mem.get(film_key) == lang:
        return
    mem[film_key] = lang
    try:
        _AUDIO_MEM_FILE.parent.mkdir(parents=True, exist_ok=True)
        _AUDIO_MEM_FILE.write_text(json.dumps(mem))
    except OSError:
        pass


def _choose_audio(audio, film_key, pref=None):
    """The track to play for a fresh cast, "preferred language first":
      1. the viewer's REMEMBERED choice for this film, if present — so an anime
         switched to Japanese once stays Japanese;
      2. else the viewer's preferred language (English) whenever a track for it
         exists — an English film mislabeled by a foreign rip (Sahara's Italian
         `default` flag) still plays English;
      3. else the release's shipped/original default (a true foreign film that
         has no preferred-language track — The Raid -> Indonesian)."""
    if not audio:
        return 0
    pref = pref if pref is not None else _pref_audio_lang()
    want = _audio_mem().get(film_key or "")
    if want:
        langed = [t for t in audio if _lang_matches(t.get("lang"), want)]
        if langed:
            return _best_quality(langed, want)
    prefer = [t for t in audio if _lang_matches(t.get("lang"), pref)]
    if prefer:
        return _best_quality(prefer, pref)
    return _default_audio(audio, pref)


def _forced_sub(subs, want_lang=None):
    """Index (into `subs`) of a FORCED subtitle to auto-display — the foreign-
    dialogue lines a film shows on purpose, separate from full CC. Detected by the
    `forced` disposition or a "forced"/"forced narrative" title. Prefer one whose
    language matches what the viewer is HEARING (so an English listener gets the
    forced lines in English), else the first forced. -1 if none.

    Only TEXT forced tracks — a bitmap forced sub would have to burn in and drop
    HDR, which is the wrong default; the viewer can still enable it by hand."""
    forced = [t for t in subs if t.get("text") and
              (t.get("forced") or "forced" in (t.get("title") or "").lower())]
    if not forced:
        return -1
    if want_lang:
        m = [t for t in forced if _lang_matches(t.get("lang"), want_lang)]
        if m:
            return subs.index(m[0])
    # the LIST index — the track's own `i` happened to equal it on a LAN probe,
    # but a roaming list (the hub's party_sub_tracks) has gaps
    return subs.index(forced[0])


def thumb_url(thumb, base):
    """A Cast metadata image the TV can actually FETCH.

    Every poster in the library is stored as an absolute LOCAL path
    (~/.cache/codec/art/….jpg — all 797 of them), and that path rode
    straight through into the LOAD as the metadata image, so the television was
    asked to fetch a filesystem path over HTTP and its overlay came up blank.

    The receiver's own paused card never showed the fault because card_into()
    already routes its poster through /art?f=; only the TV's own overlay was hit.
    That is also why it looked intermittent rather than broken — YouTube casts
    carry real http thumbnails and always worked, so it failed on library titles
    and worked on everything else.

    app-side note: castmanager.cpp clears a file:// artUrl for the same reason and
    with the same effect — no art at all. Handled here too, so the worker is the
    single place that knows how a poster becomes a URL."""
    if not thumb:
        return ""
    if thumb.startswith(("http://", "https://")):
        return thumb                      # already fetchable (YouTube, satellite)
    if thumb.startswith("file://"):
        # A file URL is percent-ENCODED; take the real path back out before the
        # basename is re-quoted below, or a poster with a space in it ships as
        # %2520 and 404s.
        thumb = unquote(urlparse(thumb).path)
    if thumb.startswith("/"):
        # No base means nothing the TV could resolve; an unfetchable URL makes the
        # receiver retry and log, so send nothing rather than something broken.
        return f"{base}/art?f={quote(os.path.basename(thumb), safe='')}" if base else ""
    return thumb


def card_into(data, s, art_url=""):
    """Attach what the receiver's paused panel shows, if there is any.

    Two lines out of it: what the FILE is (runtime, resolution, dynamic range,
    soundtrack, score) reads as a row of instrument values, and what the FILM
    is stays underneath in sentence case."""
    card = dict(library_card(s.get("src") or ""))
    poster = card.pop("poster", "")
    base = s.get("base") or ""
    if poster and base:
        card["poster"] = f"{base}/art?f={quote(poster, safe='')}"
    elif art_url:
        card["poster"] = art_url
    for _k in ("logo", "backdrop"):
        _n = card.pop(_k, "")
        if _n and base:
            card[_k] = f"{base}/art?f={quote(_n, safe='')}"
    # the soundtrack the TV's readout derives the lane's audio from: the
    # source track's channels (the DV/HDR10 lanes keep up to 5.1, the SDR
    # ladder is stereo, direct play passes the track itself)
    _au = s.get("audio") or []
    if _au:
        _ai = s.get("aidx") or 0
        _at = _au[_ai] if 0 <= _ai < len(_au) else _au[0]
        card["ach"] = int(_at.get("channels") or 0)
        card["audio"] = audio_line([_at])
    bits = [card.pop("run", "")]
    bits += card.pop("quality", [])          # "1080p", or "4K" + "HDR"
    bits.append(audio_line(s.get("audio") or []))
    bits.append(card.pop("rate", ""))
    bits = [b for b in bits if b]
    if bits:
        card["meta"] = "  ·  ".join(bits)
    # The screen-mode zoom scale rides customData so the receiver re-asserts it on
    # every load — a fresh cast (1.0 = fit) and, crucially, a seek-rewarm on the
    # dash lanes (so a scrub doesn't snap a zoomed picture back to letterboxed).
    card["zoom"] = s.get("zoom_scale", 1)
    if s.get("zoom_tl"):
        card["zoomTl"] = s["zoom_tl"]
    # The hub sized this title's forward buffer against the DEVICE's byte
    # ceiling (dv_buffer_goal, server-side): content swings 9.7 -> 55 Mbps, so a
    # goal expressed in SECONDS is a wildly different number of BYTES per title,
    # and the receiver — which only ever sees seconds — cannot work it out. It
    # rides here, next to zoom, because this is the one builder that holds BOTH
    # the session and the outgoing customData; the previous attempt set it on
    # the session and then read it back out of an object that had already been
    # popped, so the value never once reached the TV.
    if isinstance(s.get("dv_goal"), int) and s["dv_goal"] > 0:
        card["dvGoal"] = s["dv_goal"]
    info = data.setdefault("media_info", {})
    info.setdefault("customData", {}).update(card)


def _launch_reason(cast):
    """The reason string from the last Cast LAUNCH_ERROR, if any.

    pychromecast records it on the receiver controller for every LAUNCH_ERROR
    (no listener needed — registering one would disable its own CANCELLED
    retry). It tells a *transient* refusal (CANCELLED) apart from a *persistent*
    publish/config one (NOT_FOUND / INVALID_REQUEST), which is the difference
    between "retry" and "the Cast console needs attention"."""
    try:
        lf = cast.socket_client.receiver_controller.launch_failure
        return getattr(lf, "reason", None) or "?"
    except Exception:
        return "?"


def cast_load(cast, data, timeout=30.0):
    """Start `data` on codec's receiver, falling back to Google's.

    Takes the same dict quick_play does. The fallback isn't defensive noise: an
    App ID can lapse, and a cast that plays with somebody else's chrome is
    strictly better than a cast that doesn't play. A refusal is retried a couple
    of times (it's almost always a transient LAUNCH_ERROR), and only then
    suppressed — briefly (RX_BLOCK_TTL), not for the whole session, so one
    hiccup can't silently downgrade every later cast to Google's chrome."""
    app = codec_receiver_app()
    uid = str(cast.uuid)
    if app and _RX_REFUSED.get(uid, 0) <= time.time():
        ctl = getattr(cast, "_codec_rx", None)
        if ctl is None or ctl.supporting_app_id != app:
            ctl = CodecReceiver(app)
            cast.register_handler(ctl)
            cast._codec_rx = ctl
        # The live zoom channel rides alongside — registered once, reused for the
        # life of the connection so a mid-film screen-mode toggle has somewhere to
        # send to without touching the media lane.
        if getattr(cast, "_codec_zoom", None) is None:
            zc = ZoomController()
            cast.register_handler(zc)
            cast._codec_zoom = zc
        if getattr(cast, "_codec_sub", None) is None:
            sc = SubController()
            cast.register_handler(sc)
            cast._codec_sub = sc
        if getattr(cast, "_codec_toast", None) is None:
            tc = ToastController()
            cast.register_handler(tc)
            cast._codec_toast = tc
        d = dict(data)
        # customData is how the receiver is told this is a SOLO cast: no room
        # to poll, no clock to chase, and the transport bar stays amber.
        info = dict(d.pop("media_info", None) or {})
        cd = dict(info.get("customData") or {})
        cd.setdefault("solo", True)
        # The physical-TV-remote command channel (RC): tell the receiver where to
        # POST remote keypresses (Audio/Subtitle/Channel/Red/Green) and how to key
        # them. Derived from the stream origin — customData.streamUrl on the dash
        # lane, else the media_id EVERY lane sets (SDR ladder / transcode / direct
        # / YouTube). Points at the LAN hub (:8200) for a home cast and is simply
        # unreachable for a roaming funnel cast — RC is LAN-only, like a party cmdUrl.
        pu = urlparse(cd.get("streamUrl") or d.get("media_id") or "")
        if cd.get("solo") and pu.scheme and pu.netloc:
            cd["rcUrl"] = f"{pu.scheme}://{pu.netloc}/rc"
            cd["rcKey"] = str(cast.uuid)
        info["customData"] = cd
        d["media_info"] = info
        dbg("rx customData " + json.dumps(cd)[:200])
        # A refusal is almost always an INSTANT Google LAUNCH_ERROR (measured:
        # 'refused' lands the same second as the request, never a 30s timeout),
        # frequently a transient CANCELLED that clears on a second try — so
        # attempt the custom receiver a few times before conceding to default.
        for attempt in range(RX_LAUNCH_TRIES):
            try:
                ctl.quick_play(timeout=timeout, **d)
                if _load_took(cast):
                    _RX_REFUSED.pop(uid, None)       # launched — clear any block
                    return
                why = "loaded nothing"
            except Exception as e:                   # launch or load refused
                why = f"refused ({e})"
            last = attempt == RX_LAUNCH_TRIES - 1
            dbg(f"codec receiver {app} {why} reason={_launch_reason(cast)} "
                f"attempt {attempt + 1}/{RX_LAUNCH_TRIES}"
                + ("" if last else " -> retry"))
            if not last:
                time.sleep(RX_RETRY_GAP)
        # Every attempt failed: suppress the custom receiver only briefly, so a
        # later cast tries it again instead of running on default all night.
        _RX_REFUSED[uid] = time.time() + RX_BLOCK_TTL
        dbg(f"codec receiver {app} -> default media receiver "
            f"(suppressed {int(RX_BLOCK_TTL)}s)")
    quick_play.quick_play(cast, "default_media_receiver", data, timeout=timeout)


def _load_took(cast, window=20.0):
    """Did the media actually start, or did the receiver just say "got it"?

    quick_play waits for the LOAD message to be ACKNOWLEDGED, which is a
    different question from whether anything played — a receiver that cannot
    fetch the media acks the load and then reports an error. That distinction
    is the whole of "does this work on a television that isn't the author's".

    The one known way our receiver could fail where Google's would not is
    MIXED CONTENT: our page is HTTPS and the media URLs here are plain http on
    the LAN. This Bravia does not enforce it (measured 2026-08-02) — and note
    that Google's Default Media Receiver is served over HTTPS too, so a device
    that DID enforce it would have broken direct casting long before this
    change. Either way the answer here is the same: watch for the error and go
    back to the receiver that was working.

    Ambiguity is NOT a failure. A cold encoder can take a while to hand over a
    first segment, so only an explicit ERROR falls back; running out of window
    means "still coming" and is left alone."""
    mc = cast.media_controller
    end = time.time() + window
    while time.time() < end:
        st = mc.status
        if st.player_state in ("PLAYING", "BUFFERING"):
            return True
        if st.idle_reason == "ERROR":
            return False
        time.sleep(0.4)
    return True   # nothing said no


def lan_ip(peer=None):
    """This host's address on the network that reaches `peer` (the cast
    device) — works on any LAN, not just the home subnet."""
    return codec_paths.lan_ip(peer)


def _same_subnet(a, b):
    """True when two IPv4s share a /24 — good enough for a flat home LAN. Used to
    hide a CACHED cast device that isn't on our current network (a friend's TV
    when we're home, the home TV when roaming) so it can't be offered as a dead
    auto-pick target — that's how a stale off-network 'Lounge TV' got cast to."""
    try:
        return bool(a) and bool(b) and a.rsplit(".", 1)[0] == b.rsplit(".", 1)[0]
    except Exception:
        return False


# Debug step-logging, toggled by the app's Settings // DEBUG LOG switch
# (flag file so one switch instruments the whole stack).
DEBUG_FLAG = Path.home() / ".config/codec/debug"
_DBG = {"t": 0.0, "on": False, "f": None}


def dbg(msg):
    now = time.time()
    if now - _DBG["t"] > 5:
        _DBG["t"] = now
        _DBG["on"] = DEBUG_FLAG.exists()
    if not _DBG["on"]:
        return
    try:
        if _DBG["f"] is None:
            d = Path.home() / ".cache/codec/logs"
            d.mkdir(parents=True, exist_ok=True)
            _DBG["f"] = open(d / "worker-cast.log", "a")
        _DBG["f"].write(f"{time.strftime('%H:%M:%S')} {msg}\n")
        _DBG["f"].flush()
    except Exception:
        pass


def yt_id(uri):
    if "youtube.com/watch" in uri:
        return parse_qs(urlparse(uri).query).get("v", [""])[0]
    if "youtu.be/" in uri:
        return urlparse(uri).path.lstrip("/").split("/", 1)[0]
    return ""


def _cfg():
    try:
        return json.load(open(CFG_FILE))
    except Exception:
        return {}


_CAP_FONT_KEYS = ("mgs", "mgshud", "sans", "serif", "mono")


def cap_style():
    """The caster's cast caption settings — THIS machine's config, so a
    satellite's choice rides to the TV with every LOAD: {font, color, scale, bg}."""
    cfg = _cfg()
    st = (cfg.get("settings") or {}) if isinstance(cfg, dict) else {}
    font = str(st.get("castCaptionFont") or "mgs").lower()
    color = str(st.get("castCaptionColor") or "#FFFFFF").strip()
    try:
        scale = int(float(st.get("castCaptionScale") or 72))
    except (TypeError, ValueError):
        scale = 72
    return {"font": font if font in _CAP_FONT_KEYS else "mgs",
            "color": color if re.fullmatch(r"#[0-9A-Fa-f]{6}", color) else "#FFFFFF",
            "scale": max(50, min(150, scale)), "bg": bool(st.get("castCaptionBg"))}


def cap_style_token():
    """cap_style() as the hub's `substyle` lane parameter (`font|RRGGBB|box`):
    the burned lanes (a piped fallback, every YouTube cast) wear the same face."""
    c = cap_style()
    return f"{c['font']}|{c['color'].lstrip('#').upper()}|{1 if c['bg'] else 0}"


def hub_base(peer=None):
    """The codec-serve that owns the hub media tree (and its lanes):
    syncUrl from config on satellites (laptop), this host on the hub."""
    url = (_cfg().get("syncUrl") or "").rstrip("/")
    if url:
        return url
    return f"http://{lan_ip(peer)}:{SERVE_PORT}"


# ── roaming: casting the hub's library from a foreign network ────────────────
# At home the TV and the hub share a LAN, so a cast hands the receiver a hub
# LAN URL and the bytes go straight across the wire (measured no-tunnel path,
# 2026-08-02). AWAY from home — a friend's wifi — that LAN address reaches
# nothing, so the cast instead rides the hub's Tailscale FUNNEL: the same
# token-scoped, manifest-INDEX-keyed HLS surface the browse link uses
# (`/r/<token>/hls/pl?i=<idx>`). Public HTTPS, reachable from any network,
# never exposes a filesystem path. The SDR ABR ladder is tone-mapped by the
# hub; the receiver picks its own rung off its real throughput.

MANIFEST = codec_paths.MANIFEST


def hub_funnel():
    """Public HTTPS origin Tailscale Funnel serves the hub at (config
    `hubFunnel`), or "" when it isn't set."""
    return (_cfg().get("hubFunnel") or "").rstrip("/")


_ROAM = {"t": 0.0, "lan": None}


def hub_lan_reachable():
    """Is the hub's own LAN address (from syncUrl) reachable from here right
    now? This is the home-vs-away switch: reachable = same LAN, cast direct;
    unreachable = roaming, cast over Funnel. Cached a few seconds — every cast
    and every lane restart asks."""
    now = time.time()
    if _ROAM["lan"] is not None and now - _ROAM["t"] < 8:
        return _ROAM["lan"]
    url = (_cfg().get("syncUrl") or "")
    ok = True  # no syncUrl -> we ARE the hub; "reachable"
    if url:
        u = urlparse(url)
        ok = False
        if u.hostname:
            # A True is authoritative, but a single failed connect is NOT enough
            # to conclude 'away': right after a wake / a load-time _wedge_reload the
            # wifi hasn't come up yet, so one 1.2s timeout used to cache 'away' for
            # 8s and cast a LOCAL film over the public Funnel AT HOME (the author's
            # "casting from away" on his own network). Retry a few times — ~5s
            # worst case — so a slow-but-present LAN reads as home. Only genuine
            # absence (every retry fails) caches away.
            for attempt in range(3):
                try:
                    socketlib.create_connection(
                        (u.hostname, u.port or SERVE_PORT), timeout=1.2).close()
                    ok = True
                    break
                except Exception:
                    if attempt < 2:
                        time.sleep(0.6)
    _ROAM.update(t=now, lan=ok)
    return ok


def hub_allow_tv(ip):
    """A paired-only hub answers a TV only while something is cast to it
    (codec_pairing.py): tell it this TV's address before the LOAD. On the hub
    itself over loopback (its own LAN address wouldn't read as "itself"); on a
    satellite through syncUrl with its key. Quick and best-effort: a hub that
    trusts its network (the author's) doesn't need it, and away from home the cast
    rides the token surface instead."""
    if not ip:
        return
    url = (_cfg().get("syncUrl") or "").rstrip("/") or f"http://127.0.0.1:{SERVE_PORT}"
    try:
        req = urllib.request.Request(url + "/pair/tv", data=json.dumps({"ip": ip}).encode(),
                                     headers={"Content-Type": "application/json",
                                              **codec_paths.hub_headers()}, method="POST")
        urllib.request.urlopen(req, timeout=1.5).read()
    except Exception as e:
        dbg(f"allow-tv {ip}: {e}")


def hub_ctrl_base():
    """A PRIVATE address for the hub's :8200 control surface that works even
    when roaming — the hub's Tailscale IP, matched to the Funnel hostname (the
    public Funnel surface is read-only, so minting a token has to go over the
    tailnet). Falls back to syncUrl when the match fails."""
    host = urlparse(hub_funnel()).hostname
    if host:
        try:
            out = subprocess.run(["tailscale", "status", "--json"],
                                 capture_output=True, text=True,
                                 timeout=4).stdout
            for p in (json.loads(out).get("Peer") or {}).values():
                if (p.get("DNSName") or "").rstrip(".") == host:
                    ips = p.get("TailscaleIPs") or []
                    v4 = next((i for i in ips if ":" not in i), "")
                    if v4:
                        return f"http://{v4}:{SERVE_PORT}"
        except Exception:
            pass
    # Fall back to the LAN syncUrl ONLY when it's actually reachable (at home).
    # While roaming it's dead, so returning it just makes the token mint hang on
    # a doomed connect before failing — return "" so the caller fails fast.
    lan = (_cfg().get("syncUrl") or "").rstrip("/")
    return lan if hub_lan_reachable() else ""


# ── Wake-on-LAN: let the desktop hub nap (#224) ──────────────────────────────
# Every high-end cast needs the hub AWAKE (it serves the media, hosts the funnel,
# owns the GPU). If it's asleep but I'm on its LAN, wake it with a magic packet
# and wait for it to serve, then cast direct — instead of failing or falling
# through to the (also-dead) funnel path. Gated on on_hub_lan() because a magic
# packet is an L2 broadcast that only reaches the hub when we share its subnet.

def _hub_ip():
    """The hub's LAN IP (from syncUrl), or '' when unresolvable / we ARE the hub."""
    host = urlparse(_cfg().get("syncUrl") or "").hostname
    if not host:
        return ""
    try:
        return socketlib.gethostbyname(host)
    except Exception:
        return ""


def on_hub_lan():
    """Am I physically on the HUB's /24? This is the gate WoL fires behind —
    distinct from hub_lan_reachable(), which can't tell 'asleep at home' from
    'away'. Works while the hub is ASLEEP: lan_ip()'s UDP connect just picks the
    egress interface toward the hub's IP and needs no reply."""
    hub_ip = _hub_ip()
    if not hub_ip:
        return False
    mine = lan_ip(hub_ip)
    return mine.rsplit(".", 1)[0] == hub_ip.rsplit(".", 1)[0]


def wake_hub():
    """Send a Wake-on-LAN magic packet to the hub's NIC (config `hubMac`).
    Broadcast on the local /24 (config `hubBroadcast` override) to UDP 9 AND 7,
    a few times for reliability. Returns True if a packet went out, False if WoL
    isn't configured. Pure stdlib; mirrors lan_ip's socket idiom + SO_BROADCAST."""
    mac = (_cfg().get("hubMac") or "").replace(":", "").replace("-", "").strip()
    if len(mac) != 12:
        return False
    try:
        mac6 = bytes.fromhex(mac)
    except ValueError:
        return False
    packet = b"\xff" * 6 + mac6 * 16          # 6×0xFF sync + 16×MAC = 102 bytes
    hub_ip = _hub_ip()
    bcast = (_cfg().get("hubBroadcast")
             or (_bcast24(lan_ip(hub_ip)) if hub_ip else "255.255.255.255"))
    s = socketlib.socket(socketlib.AF_INET, socketlib.SOCK_DGRAM)
    s.setsockopt(socketlib.SOL_SOCKET, socketlib.SO_BROADCAST, 1)
    try:
        for _ in range(3):
            for port in (9, 7):
                try:
                    s.sendto(packet, (bcast, port))
                except Exception:
                    pass
        dbg(f"WoL magic packet -> {mac} via {bcast}")
        return True
    finally:
        s.close()


def _bcast24(ip):
    """The /24 broadcast for `ip` (192.168.1.20 -> 192.168.1.255)."""
    return ip.rsplit(".", 1)[0] + ".255"


def wait_hub_ready(base, budget=45.0):
    """Poll {base}/hls/ok until the hub answers ok, or `budget` s elapse. Hits
    /hls/ok DIRECTLY (hub_has_hls memoizes False forever per base). Re-sends the
    magic packet once ~10 s in, in case the first was missed mid-resume."""
    import urllib.request
    start = time.time()
    rewoke = False
    while time.time() - start < budget:
        try:
            d = json.loads(urllib.request.urlopen(
                f"{base}/hls/ok", timeout=2).read())
            if d.get("ok"):
                return True
        except Exception:
            pass
        if not rewoke and time.time() - start > 10:
            rewoke = True
            wake_hub()
        time.sleep(1.5)
    return False


def _hub_up_over_tailnet():
    """Does the hub's :8200 answer at its Tailscale address right now?"""
    host = urlparse(hub_funnel()).hostname
    if not host:
        return False
    try:
        out = subprocess.run(["tailscale", "status", "--json"],
                             capture_output=True, text=True, timeout=4).stdout
        for p in (json.loads(out).get("Peer") or {}).values():
            if (p.get("DNSName") or "").rstrip(".") == host:
                v4 = next((i for i in p.get("TailscaleIPs") or [] if ":" not in i), "")
                if v4:
                    socketlib.create_connection((v4, SERVE_PORT), timeout=2).close()
                    return True
    except Exception:
        pass
    return False


def hub_reachable_or_wake():
    """Home-vs-away decision WITH a wake step (#224):
      True  -> hub is up (already, or we just woke it) -> cast direct-LAN
      False -> genuinely away (not on the hub's LAN)   -> roam over the Funnel
      None  -> asleep at home but the wake FAILED       -> caller aborts (cast_error sent)."""
    if hub_lan_reachable():
        return True
    if on_hub_lan() and (_cfg().get("hubMac") or ""):
        # on_hub_lan() is only a /24 prefix match: a friend's router on the
        # same 192.168.0.x looks like home, and the cast was ABORTED after a
        # 45 s wake wait instead of roaming. A hub that answers over the
        # tailnet is awake — so its LAN address failing means we're not on it.
        if _hub_up_over_tailnet():
            dbg("on a /24 like the hub's but the hub is awake on the tailnet -> away")
            return False
        send({"event": "hub_waking"})       # forward-compat; unknown events ignored
        dbg("hub unreachable but on its LAN -> Wake-on-LAN")
        wake_hub()
        if wait_hub_ready(hub_base()):
            _ROAM.update(t=0.0, lan=None)   # bust the 8s cache so re-probe = True
            dbg("hub woke and is serving")
            return True
        send({"event": "cast_error",
              "error": "the hub didn't wake in time — is it plugged in and is "
                       "Wake-on-LAN enabled in its BIOS?"})
        return None
    return False


_TOKEN = {"tok": "", "exp": 0.0}
# The browse token this machine last held, kept on disk so a satellite that
# reaches the hub only from the internet (no tailnet to mint over) still has
# its road. The app writes it too whenever a private road is up.
_TOKEN_FILE = Path.home() / ".cache/codec/hub-token.json"


def token_file_read():
    """{token, expires, direct, funnel} from the token file, or {} when there is
    none or it has (nearly) expired."""
    try:
        d = json.loads(_TOKEN_FILE.read_text())
        if d.get("token") and float(d.get("expires") or 0) > time.time() + 60:
            return d
    except Exception:
        pass
    return {}


def token_file_write(tok, exp, extra=None):
    try:
        _TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
        d = token_file_read() or {}
        # The same token never gets SHORTER here: the hub keeps a live home
        # token on a 60-day slide and answers a 12 h ask with "12 h" — writing
        # that over the app's 60 days threw the key away after half a day
        # without a tailnet, the very case the file exists for.
        if d.get("token") == tok:
            exp = max(float(d.get("expires") or 0), float(exp))
        d.update({"token": tok, "expires": float(exp)})
        d.update(extra or {})
        tmp = _TOKEN_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps(d))
        os.chmod(tmp, 0o600)          # a 60-day key to the whole library: owner only
        tmp.replace(_TOKEN_FILE)
    except Exception:
        pass


def browse_token():
    """A browse token minted on the hub (over the tailnet), cached until it
    nears expiry. Same capability the browse link uses — it scopes the Funnel
    media URLs the TV fetches. `new:False` reuses whatever link is already live
    instead of rotating it. With no private road to mint over, the token this
    machine last held (the file the app and this worker keep) is the road."""
    now = time.time()
    if _TOKEN["tok"] and now < _TOKEN["exp"] - 600:
        return _TOKEN["tok"]
    ctrl = hub_ctrl_base()
    if ctrl:
        try:
            import urllib.request
            # home: the sliding 60-days-idle kind the app keeps too; new: keep
            # whatever link is live (the hub never shortens it)
            req = urllib.request.Request(
                ctrl + "/browse/start",
                data=json.dumps({"hours": 12, "new": False, "home": True}).encode(),
                headers={"Content-Type": "application/json"})
            d = json.loads(urllib.request.urlopen(req, timeout=10).read())
            # The hub names the token outright; it used to be parsed out of the
            # public url, which is EMPTY while the hub's Funnel name is unresolved
            # (codec-serve up before tailscaled) — no token, no roaming cast.
            url = (d.get("url") or "").rstrip("/")
            tok = (d.get("token") or "") or (url.rsplit("/", 1)[-1] if "/r/" in url else "")
            if tok:
                # the hub's own expiry when it says it; else the asked-for hours
                exp = float(d.get("expires") or 0)
                if exp <= now:
                    h = d.get("hours") or 0
                    exp = now + (h * 3600 if h else 30 * 86400)
                _TOKEN.update(tok=tok, exp=exp)
                token_file_write(tok, exp)
                return tok
        except Exception:
            pass
    held = token_file_read()
    if held.get("token"):
        _TOKEN.update(tok=held["token"], exp=float(held.get("expires") or 0))
        return held["token"]
    return ""


_PUBLIC = {"base": "", "t": 0.0}


def _url_answers(url, timeout):
    try:
        import urllib.request
        req = urllib.request.Request(url, method="HEAD")
        urllib.request.urlopen(req, timeout=timeout).close()
        return True
    except Exception:
        return False


def hub_public_base():
    """The public door a roaming cast rides: the house's fast road (config
    hubDirect, else what the hub says at /r/<tok>/roads — the whole upload,
    enough for a DV copy) when it answers, else the Funnel relay. Cached a
    few minutes: a cast start already serializes several round trips."""
    now = time.time()
    if _PUBLIC["base"] and now - _PUBLIC["t"] < 300:
        return _PUBLIC["base"]
    fun = hub_funnel()
    direct = (_cfg().get("hubDirect") or "").rstrip("/")
    held = token_file_read()
    if not direct and held.get("direct"):
        direct = str(held["direct"]).rstrip("/")

    def ask_roads():
        tok = browse_token()
        if not (tok and fun):
            return ""
        try:
            import urllib.request
            d = json.loads(urllib.request.urlopen(
                f"{fun}/r/{tok}/roads", timeout=8).read())
            road = (d.get("direct") or "").rstrip("/")
            if road:
                token_file_write(tok, _TOKEN["exp"], {"direct": road, "funnel": fun})
            return road
        except Exception:
            return ""

    if not direct:
        direct = ask_roads()
    base = ""
    if direct and _url_answers(direct + "/cast/receiver", 5):
        base = direct
    elif direct and not (_cfg().get("hubDirect") or ""):
        # a remembered road that stopped answering: the house may have moved
        # its edge — ask the hub once more before settling for the relay
        fresh = ask_roads()
        if fresh and fresh != direct and _url_answers(fresh + "/cast/receiver", 5):
            base = fresh
    if not base and fun and _url_answers(fun + "/cast/receiver", 6):
        base = fun          # the Funnel relay: slower, but a door
    # nothing answers → "" so the cast fails FAST with a clear word, instead of
    # a minute of dead round trips against a door that isn't there
    _PUBLIC.update(base=base, t=now if base else 0.0)
    dbg(f"public base {base or '(none)'} (direct={direct or '-'} funnel={fun or '-'})")
    return base


def manifest_index(uri):
    """Index of the entry whose url == uri, into the SAME manifest the hub's
    browse surface indexes (`_browse_entries()` reads this very file), so the
    index is a valid handle on `/r/<token>/hls/pl?i=`. -1 if not found."""
    try:
        entries = json.loads(MANIFEST.read_text()).get("entries") or []
    except Exception:
        return -1

    def key(u):  # match by PATH, host-agnostic — a roaming app rewrites the
        # hub host (LAN -> tailnet) before playing, and that rewritten uri can
        # reach a cast too; the path is the stable identity.
        return unquote(urlparse(u).path if "://" in u else u)

    want = key(uri)
    for i, e in enumerate(entries):
        u = e.get("url") or ""
        if u and key(u) == want:
            return i
    return -1


def _cap_width(model):
    """Widest h264 frame this receiver's decoder can take. The hub builds the
    ladder from the source's NATIVE width, so an ultrawide film yields a
    2582- or 3840-wide top rung — and a 1080p-class receiver ERRORS on a rung
    that exceeds its decoder rather than stepping down to a smaller one. So we
    only ever offer it a rung within this ceiling. 4K receivers take it all.

    ⚠ Until the hub encodes a rung capped to the receiver's WIDTH (not just its
    height), the highest a 1080p device can be handed here is the ladder's
    720p rung — there is nothing between it and the undecodable 2582x1080."""
    m = (model or "").lower()
    # Add UNAMBIGUOUS 4K-decode devices so a SHIELD/Apple TV 4K/console isn't
    # silently capped to 1080p. Deliberately NOT here: plain 'chromecast',
    # 'google tv', 'fire tv', bare 'bravia'/'sony'/'lg'/'samsung' — those name
    # both 4K and HD models, and handing an HD receiver a wider-than-1920 rung
    # ERRORS instead of stepping down (the whole reason this cap exists). When
    # in doubt, 1920 still plays; a wrong 3840 does not.
    wide = ("4k", "ultra", "2160", "uhd", "bravia 4k",
            "shield", "chromecast ultra", "apple tv 4k",
            "ps5", "xbox one x", "xbox series", "mibox s", "qled", "oled")
    if any(k in m for k in wide):
        return 3840
    return 1920


_HLS_OK = {}  # base -> bool (does this server carry the HLS lane?)


def hub_has_hls(base):
    """The HLS lane is the only way this receiver shows a real timeline
    (it derives fMP4 duration from arriving fragments — receiver-truth
    2026-07-19); older hubs fall back to the piped lane."""
    if base not in _HLS_OK:
        try:
            import urllib.request
            d = json.loads(urllib.request.urlopen(
                f"{base}/hls/ok", timeout=3).read())
            _HLS_OK[base] = bool(d.get("ok"))
        except Exception:
            _HLS_OK[base] = False
    return _HLS_OK[base]


def hub_preflight(base, src, aidx=0, burn=-1):
    """Ask the hub which cast lane it will serve for `src` (#219). The hub probes
    the actual file (video_info + dv_probe) and is the SINGLE authority — this
    replaces the worker's old filename/label guessing of DV/HDR/4K, which diverged
    from what the hub served (→ DV seek freezes, spurious re-warms). Returns the
    decision dict {lane, fmt, hdr, dv, ...} or None on any failure (caller then
    falls back to the universally-castable SDR ladder). Not cached: the resume
    point / burn can change per cast, and the hub's probes are already cached.

    Timeout is generous (8 s, vs 3 s for hub_has_hls): this call gates PICTURE
    QUALITY, so a false timeout costs HDR/DV (SDR fallback). A cold dv_probe on a
    large file can take a few seconds; even if we give up, the hub finishes the
    probe and caches it, so a retry returns instantly — the degradation self-heals."""
    try:
        import urllib.request
        return json.loads(urllib.request.urlopen(
            f"{base}/hls/preflight?src={quote(src, safe='')}"
            f"&aidx={aidx}&burn={burn}", timeout=8).read())
    except Exception:
        return None


def content_type(uri):
    ct = mimetypes.guess_type(uri)[0]
    if not ct:
        ct = {"mkv": "video/x-matroska", "m2ts": "video/mp2t",
              "ts": "video/mp2t"}.get(uri.rsplit(".", 1)[-1].lower(), "video/mp4")
    return ct


def probe(src):
    """ffprobe the source (local path or http): format + full track lists.
    Returns {} on any failure."""
    try:
        out = subprocess.run(
            ["/usr/bin/ffprobe", "-v", "error", "-print_format", "json",
             "-show_format", "-show_streams", src],
            capture_output=True, text=True, timeout=30).stdout
        info = json.loads(out)
    except Exception:
        return {}
    r = {"duration": float(info.get("format", {}).get("duration") or 0),
         "audio": [], "subs": [], "video": ""}
    for st in info.get("streams", []):
        tags = st.get("tags") or {}
        kind = st.get("codec_type")
        if kind == "video" and not r["video"]:
            r["video"] = st.get("codec_name", "")
        elif kind == "audio":
            disp = st.get("disposition") or {}
            r["audio"].append({
                "i": len(r["audio"]),
                "codec": st.get("codec_name", ""),
                "lang": tags.get("language", ""),
                "title": tags.get("title", ""),
                "channels": st.get("channels", 0),
                "default": int(disp.get("default", 0) or 0),
                "forced": int(disp.get("forced", 0) or 0)})
        elif kind == "subtitle":
            codec = st.get("codec_name", "")
            disp = st.get("disposition") or {}
            r["subs"].append({
                "i": len(r["subs"]),
                "codec": codec,
                "lang": tags.get("language", ""),
                "title": tags.get("title", ""),
                "text": codec in TEXT_SUBS,
                "default": int(disp.get("default", 0) or 0),
                "forced": int(disp.get("forced", 0) or 0)})
    return r


# ── worker-embedded server: casts media that lives on THIS machine ─────────
# Files this worker has been asked to cast — the ONLY paths the endpoints
# will touch (keeps the LAN from browsing the disk).
_allowed = set()
_allowed_lock = threading.Lock()


def allow_path(p):
    with _allowed_lock:
        _allowed.add(os.path.realpath(p))


def path_allowed(p):
    with _allowed_lock:
        return os.path.realpath(p) in _allowed


class SelfServeHandler(BaseHTTPRequestHandler):
    # HTTP/1.1 is load-bearing for cast receivers (the Bravia's media loader
    # refuses 1.0 — hub finding 2026-07-19). Bounded responses carry
    # Content-Length; the transcode stream sets Connection: close.
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def end_headers(self):
        # Cast receivers require CORS on media AND sideloaded track requests.
        self.send_header("Access-Control-Allow-Origin", "*")
        super().end_headers()

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path.startswith("/file"):
            self._serve_file(unquote(q.get("path", [""])[0]))
        elif u.path.startswith("/transcode"):
            self._serve_transcode(unquote(q.get("src", [""])[0]), q)
        elif u.path.startswith("/subready"):
            self._serve_subready(unquote(q.get("src", [""])[0]), q)
        elif u.path.startswith("/subs"):
            self._serve_subs(unquote(q.get("src", [""])[0]), q)
        else:
            self.send_error(404)

    def _serve_file(self, path):
        if not path_allowed(path) or not os.path.isfile(path):
            self.send_error(404)
            return
        size = os.path.getsize(path)
        rng = self.headers.get("Range", "")
        start, end = 0, size - 1
        status = 200
        if rng.startswith("bytes="):
            try:
                a, b = rng[6:].split("-", 1)
                start = int(a) if a else 0
                end = int(b) if b else size - 1
                status = 206
            except ValueError:
                pass
        end = min(end, size - 1)
        self.send_response(status)
        self.send_header("Content-Type",
                         mimetypes.guess_type(path)[0] or "video/mp4")
        self.send_header("Accept-Ranges", "bytes")
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        try:
            with open(path, "rb") as f:
                f.seek(start)
                remaining = end - start + 1
                while remaining > 0:
                    chunk = f.read(min(256 * 1024, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass  # receiver seeked/stopped — normal

    def _serve_transcode(self, src, q):
        if not path_allowed(src) or not os.path.isfile(src):
            self.send_error(404)
            return
        cmd = hublib.transcode_cmd(src,
                                   float(q.get("start", ["0"])[0]),
                                   q.get("v", [""])[0],
                                   int(q.get("aidx", ["0"])[0]),
                                   int(q.get("burn", ["-1"])[0]),
                                   q.get("mode", ["fit"])[0],
                                   hublib.NVENC,
                                   float(q.get("subsize", ["1"])[0]))
        # hublib's lane registry: superseded swaps kill their old encoder.
        ff = hublib.lane_start(src, cmd)
        self.connection.settimeout(30)
        self.send_response(200)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
            while True:
                chunk = ff.stdout.read(256 * 1024)
                if not chunk:
                    break
                self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError, OSError, ValueError):
            pass
        finally:
            hublib.lane_done(src, ff)

    def _serve_subready(self, src, q):
        if not path_allowed(src) or not os.path.isfile(src):
            self.send_error(404)
            return
        body = json.dumps(
            {"ready": hublib.burn_ready(src, int(q.get("i", ["0"])[0]))}
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve_subs(self, src, q):
        if not path_allowed(src) or not os.path.isfile(src):
            self.send_error(404)
            return
        vtt = hublib.extract_vtt(src, int(q.get("i", ["0"])[0]))
        if not vtt:
            self.send_error(404)
            return
        data = vtt.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "text/vtt")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


DEVCACHE = Path.home() / ".cache/codec/devices.json"


def _same_film(a, b):
    """True when two cast content_ids are the SAME underlying stream, differing
    only in re-warm params (warm=/start=) — i.e. our own DV/HLS lane re-loading
    itself, not a foreign session taking over the TV. Keyed on the src (file) or
    v (youtube) query param. Lets new_media_status treat a self re-warm as an
    in-place URL update instead of a full re-attach (which drops dv_lane)."""
    # Everything ELSE must match too. Keyed on src alone, ANOTHER codec casting
    # the same film (the laptop resuming what the desktop cast — a different
    # aidx, a DV lane vs a ladder, another host) read as our own re-warm, and
    # both workers stayed owners of one TV and fought over its lane. The
    # receiver's re-warm (rewarmTo) rewrites only warm=.
    try:
        from urllib.parse import urlparse, parse_qs
        ua, ub = urlparse(a), urlparse(b)
        qa, qb = parse_qs(ua.query), parse_qs(ub.query)
        # src (a hub file), i (a roaming title on the token surface — its url
        # carries neither src nor a YouTube v; keyed on the codec name in v=
        # by accident before, so a probe that timed out made the receiver's
        # own DV re-warm read as a takeover), or v (YouTube)
        ka = (qa.get("src") or qa.get("i") or qa.get("v") or [None])[0]
        kb = (qb.get("src") or qb.get("i") or qb.get("v") or [None])[0]
        if not ka or ka != kb:
            return False
        if (ua.scheme, ua.netloc, ua.path) != (ub.scheme, ub.netloc, ub.path):
            return False
        rewarm = {"warm", "start", "dvWarm"}
        return ({k: v for k, v in qa.items() if k not in rewarm}
                == {k: v for k, v in qb.items() if k not in rewarm})
    except Exception:
        return False


class Worker:
    def __init__(self):
        self.zconf = zeroconf_mod.Zeroconf()
        self.devices = {}          # uuid-str -> CastInfo
        self.known = {}            # uuid-str -> cached dict (mDNS fallback)
        self.cast = None           # connected Chromecast
        self.cast_id = ""
        self.status_stop = threading.Event()
        # The live cast session (None when idle / YouTube-native).
        self.sess = None
        self.last_pos = 0.0
        # Lane watchdog state (see _lane_watchdog).
        self.inbox = None          # main loop's queue, for safe recovery ops
        self.pending_seek = None   # (target_abs_pos, asked_at)
        self.buf_since = None
        self.had_played = False
        self.lane_started_at = 0.0
        # Roaming DV / HDR10 lane starvation (see _roam_starved): buffering
        # seconds in a rolling two-minute window, and when the lane was loaded.
        self.roam_tick = 0.0
        self.roam_buf = []
        self.roam_dash_since = 0.0
        self.roam_last_pos = None
        # Mid-stream frozen-PLAYING detector (fallback for a stale/cached receiver;
        # the receiver's own stall-guard is primary and recovers in ~20s). RAW pos.
        self.frozen_pos = None
        self.frozen_since = 0.0
        self.last_crash_recover = 0.0
        self.last_load_req = None       # remembered req, for the load-time wedge re-load heal
        self.load_wedge_at = 0.0        # cooldown so the heal can't loop-cast
        self.last_seek_at = 0.0
        # Stall-recovery backoff (see _lane_watchdog): a 4K DV cast can buffer
        # for a few seconds on a heavy scene without being wedged, and a re-warm
        # itself buffers ~20-30s, so a twitchy recovery makes a transient stall
        # WORSE and can loop (observed: re-seeking the same spot every ~35s).
        # Recover only on a sustained stall, and back off if re-warming isn't
        # restoring playback.
        self.recover_count = 0          # consecutive recoveries without healthy play
        self.last_recover_at = 0.0
        listener = pychromecast.discovery.SimpleCastListener(
            self._added, self._removed)
        self.browser = pychromecast.discovery.CastBrowser(
            listener, self.zconf)
        self.browser.start_discovery()
        # Cast devices (the Bravia, live and in the wild) sometimes stop
        # announcing over mDNS while the cast port stays open. Surface every
        # previously seen device so casting still works; connect() falls back
        # to its cached IP when discovery hasn't found it.
        try:
            self.known = json.loads(DEVCACHE.read_text())
        except Exception:
            self.known = {}
        my_ip = lan_ip()
        for u, d in self.known.items():
            ip = d.get("ip", "")
            # Only surface a CACHED device that's on our current network. Live
            # zeroconf (_added) still surfaces any device actually present; this
            # gate is only for the mDNS-fallback cache, so a device remembered
            # from another network isn't offered as a dead target here (a stale
            # off-network "Lounge TV" was being auto-picked at home).
            if not _same_subnet(ip, my_ip):
                continue
            send({"event": "device", "id": u, "name": d["name"],
                  "model": d.get("model", ""), "ip": ip})
        try:
            self.selfsrv = ThreadingHTTPServer(("0.0.0.0", SELF_PORT),
                                               SelfServeHandler)
            threading.Thread(target=self.selfsrv.serve_forever,
                             daemon=True).start()
        except OSError:
            self.selfsrv = None  # port taken (second instance) — hub casts still work

    # -- discovery callbacks (zeroconf threads) --------------------------
    def _added(self, uuid, _service):
        info = self.browser.devices.get(uuid)
        if not info:
            return
        self.devices[str(uuid)] = info
        send({"event": "device", "id": str(uuid),
              "name": info.friendly_name, "model": info.model_name,
              "ip": str(info.host)})
        self.known[str(uuid)] = {"name": info.friendly_name,
                                 "model": info.model_name,
                                 "ip": str(info.host)}
        # A cast device's UUID can change (a TV firmware update / factory reset
        # regenerates it), and the OLD id lingers in the device cache — sent again
        # at the next startup as a phantom DUPLICATE of the same TV that can never
        # be dialed. When a LIVE device confirms an IP, evict any other known entry
        # that shares it.
        ip = str(info.host)
        for old in [u for u, d in self.known.items()
                    if u != str(uuid) and d.get("ip") == ip]:
            self.known.pop(old, None)
            self.devices.pop(old, None)
            send({"event": "device_gone", "id": old})
        try:
            DEVCACHE.parent.mkdir(parents=True, exist_ok=True)
            DEVCACHE.write_text(json.dumps(self.known))
        except Exception:
            pass

    def _removed(self, uuid, _service, _info):
        self.devices.pop(str(uuid), None)
        send({"event": "device_gone", "id": str(uuid)})

    # -- the output picker's ADD DEVICE row --------------------------------
    SCAN_SECS = 8

    def rescan(self):
        """A fresh LAN search: a short-lived SECOND mDNS browser on the same
        zeroconf instance, feeding the same callbacks (_added), so a device that
        went quiet answers the new queries. The main browser keeps running —
        stopping it would close the shared zeroconf and end the host poller for
        good. Reports scan_done with how many devices turned up that weren't
        listed before. Nothing is cast."""
        before = set(self.devices) | set(self.known)
        try:
            extra = zeroconf_mod.ServiceBrowser(
                self.zconf, "_googlecast._tcp.local.", self.browser.zeroconf_listener)
        except Exception as e:
            send({"event": "scan_done", "found": 0, "error": str(e)})
            return

        def finish():
            try:
                extra.cancel()
            except Exception:
                pass
            found = len((set(self.devices) | set(self.known)) - before)
            send({"event": "scan_done", "found": found})
        threading.Timer(self.SCAN_SECS, finish).start()

    def add_ip(self, ip):
        """ADD DEVICE by address, for a device mDNS can't see: ask the IP itself
        (its eureka_info — read-only, nothing is cast). If a cast device answers,
        list it like a discovered one — cached, so it's offered next time too —
        and hand it to the host browser so it stays polled."""
        def work():
            try:
                ipaddress.ip_address(ip)
            except ValueError:
                send({"event": "add_ip_result", "ip": ip, "ok": False,
                      "error": "not an IP address"})
                return
            try:
                st = pychromecast.discovery.get_device_info(ip, timeout=6)
            except Exception:
                st = None
            if not st or not st.uuid:
                send({"event": "add_ip_result", "ip": ip, "ok": False,
                      "error": "no cast device answered"})
                return
            u = str(st.uuid)
            d = {"name": st.friendly_name, "model": st.model_name, "ip": ip}
            self.known[u] = d
            try:
                DEVCACHE.parent.mkdir(parents=True, exist_ok=True)
                DEVCACHE.write_text(json.dumps(self.known))
            except Exception:
                pass
            send({"event": "device", "id": u, **d})
            try:
                self.browser.host_browser.add_hosts([ip])
            except Exception:
                pass
            send({"event": "add_ip_result", "ip": ip, "ok": True, "name": st.friendly_name})
        threading.Thread(target=work, daemon=True).start()

    # -- media status listener (socket-client thread) --------------------
    def new_media_status(self, status):
        # Snapshot self.sess ONCE. This runs on pychromecast's socket-client
        # thread; the main loop can null or replace self.sess at any GIL switch
        # (stop 1832 / disconnect / load), so re-reading it across the callback
        # races a None into the middle of a dereference -> TypeError on this
        # thread, and pychromecast just swallows the lost status. Mirror
        # _lane_watchdog, which already snapshots.
        s = self.sess
        finished = (status.player_state == "IDLE"
                    and getattr(status, "idle_reason", "") == "FINISHED")
        pos = status.adjusted_current_time or status.current_time or 0
        dur = status.duration or 0
        if s:
            pos += s["offset"]
            dur = s["duration"] or dur
        vol = 0.0
        try:
            if self.cast and self.cast.status:
                vol = self.cast.status.volume_level or 0.0
        except Exception:
            pass
        if s and status.player_state in ("PLAYING", "PAUSED", "BUFFERING"):
            # A position read right after a lane (re)start is unreliable, and
            # last_pos feeds partyPublishCast's room pin + the resume write, so a
            # bad value must not clobber a real one. Two failure modes, one guard
            # (lane_started_at is stamped at every lane load; last_pos is set to the
            # target there too):
            #  #3  re-warm DIP  — the reloaded lane reports ~0 for a few seconds
            #      before settling at the target; hold through it.
            #  #23 switch SPIKE — for ~1.5s the receiver's OLD-stream relative time
            #      can combine with a freshly-mutated s['offset'], spiking the pos;
            #      a big jump either way right at the switch is not real.
            dt = time.time() - self.lane_started_at
            rewarm_dip = (dt < 8.0 and pos < 5.0 and self.last_pos > 30.0)
            switch_spike = (dt < 2.0 and self.last_pos > 0
                            and abs(pos - self.last_pos) > 60.0)
            if not (rewarm_dip or switch_spike):
                self.last_pos = pos
            # YouTube-native sessions learn their duration from the receiver
            # (there's nothing to ffprobe) — keep it across lane switches.
            if not s["duration"] and (status.duration or 0) > 0:
                s["duration"] = status.duration
        cid = getattr(status, "content_id", "") or ""
        if (s and cid and s.get("media_id")
                and cid != s["media_id"]
                and status.player_state in ("PLAYING", "BUFFERING")
                and time.time() - self.lane_started_at > 5):
            # A DV/HLS re-warm re-loads the SAME film at a new warm=/start=: the
            # content_id changes but this is OUR lane, not a foreign takeover.
            # Adopt the new URL in place so the session keeps its identity (owner,
            # dv_lane) and seeks stay on the fast non-blocking path — rebuilding as
            # a passive remote here dropped dv_lane and reverted the next seek to
            # the blocking path that froze the loop + spawned a junk lane (mash-IDLE).
            if _same_film(cid, s["media_id"]):
                s["media_id"] = cid
                return
            # Another codec swapped the TV's content under us (desktop
            # switched to a YT vid mid-Alien, laptop remote still showed
            # Alien) — adopt the new session instead of narrating the old one.
            # QUEUE the attach to the main loop (op:'attach') rather than
            # building self.sess from this socket thread: connect() fully
            # reassigns self.sess and would race set_sub/seek on the main thread.
            dbg(f"takeover -> re-attach {cid[:140]}")
            # Throttle: self.sess keeps its old media_id until the queued attach
            # runs on the main loop, so every status tick in between would re-queue.
            if self.inbox and time.time() - getattr(self, "_takeover_at", 0) > 5:
                self._takeover_at = time.time()
                self.inbox.put(json.dumps(
                    {"op": "attach", "device": self.cast_id, "internal": True}))
            return
        if (status.player_state == "IDLE"
                and getattr(status, "idle_reason", "") == "ERROR"
                and s and s.get("lane") and self.had_played
                # Only the worker that LOADED the lane may auto-recover it.
                # Two codecs watching one TV both recovering = they evict
                # each other's encoders in a loop (2026-07-19 crash class).
                and s.get("owner")):
            # Lane died mid-flight (encoder crash, network blip — the
            # 2026-07-18 i,Robot cutout): resume at the last position, once —
            # a broken file must not turn into a restart loop.
            now = time.time()
            dur = s["duration"] or 0
            # HLS cold seeks throw transient IDLE(ERROR) while segments
            # build — reloading then just churns; give seeks breathing room.
            settled = not s.get("hls") or now - self.last_seek_at > 15
            if (settled and now - self.last_crash_recover > 45
                    and (not dur or self.last_pos < dur - 20)):
                self.last_crash_recover = now
                send({"event": "cast_error",
                      "error": "stream hiccup — resuming where you were"})
                self._recover(self.last_pos)
                return
        self._lane_watchdog(status.player_state, pos, status.current_time or 0)
        send({"event": "status", "state": status.player_state or "IDLE",
              "position": pos, "duration": dur, "volume": vol,
              "rate": getattr(status, "playback_rate", 1.0) or 1.0,
              "finished": finished})

    def _stall_escalate(self, pos):
        """Escalate a confirmed mid-stream stall: first a re-warm (_recover), then a
        quit+clean reload on repeats (never give up). Shared backoff via recover_count."""
        self.recover_count += 1
        self.last_recover_at = time.time()
        if self.recover_count == 1:
            dbg(f"stall escalate #1 — re-warm at {int(pos or 0)}s")
            self._recover(pos)
        elif self.inbox:
            dbg(f"stall escalate #{self.recover_count} — quit_app + clean reload at {int(pos or 0)}s")
            self.inbox.put(json.dumps(
                {"op": "_wedge_reload", "position": pos, "internal": True}))

    def _roam_starved(self, state, now, pos):
        """Away from home on the DV / HDR10 lane — the film's own bitrate (a DV
        copy is ~35-80 Mbps), which a thin link can't feed. The party receiver's
        rule, applied from this side (a solo receiver has no other lane to turn
        to on its own): 25 s of buffering inside any two minutes after the first
        real play, or no picture at all 45 s after the load, and the cast
        re-loads on the adaptive ladder at the same spot, for the rest of this
        cast. No climbing back: the ladder's top rung is 1080p-class and it
        rides the real throughput itself. True when it fired."""
        dt = min(5.0, now - self.roam_tick) if self.roam_tick else 0.0
        self.roam_tick = now
        # A SEEK buffers by design — a DV far seek re-warms through the
        # receiver (~11-14 s of the v1.27 deep buffer, never shrink it) and
        # the worker's own seeks restart the lane. None of that is the link's
        # fault: nothing counts for 20 s after a seek we sent, 15 s after a
        # lane start, or after the picture JUMPED (the TV's own remote).
        jumped = (self.roam_last_pos is not None and pos is not None
                  and abs(pos - self.roam_last_pos) > 30)
        if jumped:
            self.roam_jump_at = now
        self.roam_last_pos = pos
        quiet = (now - self.last_seek_at < 20 or now - self.lane_started_at < 15
                 or now - getattr(self, "roam_jump_at", 0.0) < 20)
        if self.had_played and state == "BUFFERING" and dt > 0 and not quiet:
            self.roam_buf.append((now, dt))
        self.roam_buf = [(t, d) for (t, d) in self.roam_buf if now - t <= 120]
        buffered = sum(d for _, d in self.roam_buf)
        never = (not self.had_played and self.roam_dash_since
                 and now - self.roam_dash_since > 45
                 and state not in ("PLAYING", "PAUSED"))
        if buffered <= 25 and not never:
            return False
        why = (f"{buffered:.0f}s buffering in 2 min" if buffered > 25
               else "no picture 45 s after the load")
        # a load that never showed a picture reports ~0: step down at the
        # position we ASKED for, not the start of the film
        at = (pos or 0) if self.had_played else max(pos or 0, self.last_pos or 0)
        dbg(f"roam lane starved ({why}) -> adaptive ladder at {int(at)}s")
        self.roam_buf = []
        self.roam_dash_since = 0.0
        if self.inbox:
            self.inbox.put(json.dumps({"op": "_roam_stepdown", "position": at,
                                       "why": why, "internal": True}))
        return True

    def _lane_watchdog(self, state, pos, raw=0):
        """Lane streams are BUFFERED to the receiver so its own remote can
        seek, but only the buffered window is really seekable — a seek beyond
        it (or any stall) parks the receiver in BUFFERING. Watch for that and
        hard-restart the lane at the reported position. Runs on the socket
        thread, so recovery is queued to the main loop (a quick_play from
        here would deadlock waiting for its own reply)."""
        s = self.sess
        # Attached (non-owner) sessions observe only — recovery belongs to
        # the codec that loaded the lane. An explicit user op (seek, track
        # change) rebuilds the lane and takes ownership deliberately.
        if not s or not s.get("lane") or not s.get("owner"):
            return
        now = time.time()
        if s.get("hls"):
            # Away from home on the DV / HDR10 lane: a link that can't feed the
            # film's own bitrate steps down to the adaptive ladder (before the
            # wedge heal below, which would only re-load the same lane).
            if (s.get("roam") and s.get("dash_cast") and not s.get("force_ladder")
                    and self._roam_starved(state, now, pos)):
                return
            # Load-time wedge: a device-flap during the load leaves the receiver
            # HALF-ARMED — it ACKs the load and even pulls segments, but the
            # picture never starts (frozen at ~0, never PLAYING). Every existing
            # recovery below needs had_played, so this slips through and the TV
            # sits on IDLE. Heal it the way the manual fix does (force-stop the
            # receiver + re-cast): quit the receiver app and re-issue the SAME
            # load. The flap is a one-time mDNS event, so a fresh load starts
            # clean; a seek-recover re-wedges, a full re-load doesn't.
            # Only while it has NOT started: a PLAYING (or user-PAUSED) report
            # is a slow-but-healthy start, and quitting the receiver on it
            # re-cast a title that was already playing (the frozen-PLAYING
            # wedge below owns a stuck clock).
            if (not self.had_played and self.last_load_req
                    and state not in ("PLAYING", "PAUSED")
                    and now - self.lane_started_at > 18
                    and (pos or 0) < 3
                    and now - self.load_wedge_at > 40):
                self.load_wedge_at = now
                dbg("load-time wedge (frozen at start) — quit_app + clean re-load")
                if self.inbox:
                    self.inbox.put(json.dumps(
                        {"op": "_wedge_reload", "internal": True}))
                return
            # HLS builds segments on demand — BUFFERING is normal work, so
            # only a LONG stall (dead encoder) triggers a playlist reload.
            if state == "PLAYING":
                self.had_played = True
                self.buf_since = None
                if self.recover_count and now - self.last_recover_at > 45:
                    self.recover_count = 0
                # Frozen-PLAYING wedge: the receiver reports PLAYING with a FROZEN
                # clock (mid-stream audio starvation). The receiver's own stall-guard
                # is primary (~20s); this is the fallback for a stale/cached receiver.
                # RAW pos only — adjusted_current_time extrapolates with wall-clock
                # while PLAYING, so a frozen cast would look like it's advancing. 30s
                # sits safely behind the receiver guard to avoid double-firing.
                if (now - self.lane_started_at > 20
                        and now - self.last_seek_at > 15 and not self.pending_seek):
                    if self.frozen_pos is not None and abs(raw - self.frozen_pos) < 0.3:
                        if now - self.frozen_since > 30:
                            dbg(f"frozen-PLAYING {int(now - self.frozen_since)}s at {int(pos or 0)}s")
                            self.frozen_since = now        # re-arm (spacing bounds escalation)
                            self._stall_escalate(pos)
                    else:
                        self.frozen_pos, self.frozen_since = raw, now
                else:
                    self.frozen_pos = None
            elif state == "BUFFERING" and self.had_played:
                self.frozen_pos = None
                if self.buf_since is None:
                    self.buf_since = now
                elif now - self.buf_since > 30:
                    self.buf_since = None
                    self._recover(pos)
            return
        ps = self.pending_seek        # #22: snapshot once — the main loop nulls
        if ps:                        # pending_seek, and a check-then-unpack of the
            tgt, asked = ps           # attribute raced a None into `tgt, asked = None`
            if abs(pos - tgt) < 8:
                if state == "PLAYING":
                    self.pending_seek = None  # native seek landed
            elif now - asked > 3:
                # Outside the buffer the Bravia either parks in BUFFERING or
                # silently IGNORES the seek and keeps playing — recover from
                # any state once the target clearly didn't happen.
                self.pending_seek = None
                self._recover(tgt)
                return
        if state == "PLAYING":
            self.had_played = True
            self.buf_since = None
            # Healthy again: once it's been playing well past the last recovery,
            # clear the backoff so a fresh stall much later gets a normal response.
            if self.recover_count and now - self.last_recover_at > 45:
                self.recover_count = 0
            return
        if state != "BUFFERING":
            return
        if self.had_played and now - self.lane_started_at > 8:
            if self.buf_since is None:
                self.buf_since = now
                return
            # A 4K DV cast buffers for a few seconds on a heavy scene / LAN dip
            # WITHOUT being wedged, and a re-warm itself buffers ~20-30s — so the
            # old 6s trigger turned a transient stall into a worse re-warm, and
            # could loop (re-seeking the same spot every ~35s). Recover only on a
            # SUSTAINED stall, and back off on repeats so a re-warm that isn't
            # helping stops thrashing.
            # First stall: a cheap in-place re-warm (_hard_seek). But on open-GOP DV
            # that path can itself re-wedge (see its own comment above), and the old
            # code then just re-seeked and, after 4 tries, GAVE UP — leaving the film
            # frozen forever (the movie-night freeze: decodedFrames stuck, no self-
            # heal, only a manual force-stop fixed it). So escalate a REPEAT stall to
            # the ONLY recovery that reliably clears a wedged receiver — quit the app
            # + clean re-load at the CURRENT spot (exactly what the manual force-stop
            # did) — and NEVER give up. Backoff grows but caps, so a genuinely
            # unplayable source retries slowly instead of looping tight or freezing.
            thresh = min(20 + 12 * self.recover_count, 56)   # 20 / 32 / 44 / 56 …
            if now - self.buf_since > thresh:
                stalled = int(now - self.buf_since)
                self.buf_since = None
                self.recover_count += 1
                self.last_recover_at = now
                if self.recover_count == 1:
                    dbg(f"stall recovery #1 (buffered {stalled}s) — re-warm at {int(pos or 0)}s")
                    self._recover(pos)
                elif self.inbox:
                    dbg(f"stall recovery #{self.recover_count} (buffered {stalled}s) — "
                        f"quit_app + clean reload at {int(pos or 0)}s")
                    self.inbox.put(json.dumps(
                        {"op": "_wedge_reload", "position": pos, "internal": True}))

    def _recover(self, position):
        # A roaming recovery is usually a 403: the browse token expired mid-film
        # or the hub rotated it, so the URL the receiver was fetching went dead.
        # Drop the cached token so the reload below re-mints a live one (see
        # _start_roam_stream) instead of looping the same dead URL forever.
        if self.sess and (self.sess.get("roam") or self.sess.get("roam_yt")):
            _TOKEN["tok"] = ""
        if self.inbox:
            self.inbox.put(json.dumps(
                {"op": "_hard_seek", "position": position, "internal": True}))

    def load_media_failed(self, queue_item_id, error_code):
        send({"event": "cast_error",
              "error": f"receiver refused media (code {error_code}) — codec/container unsupported? play locally"})

    # -- status poll so position keeps flowing ---------------------------
    def _poll(self, stop):
        # This loop is the only thing keeping cast position fresh, and resume
        # points are written from it. It must never die, but a *persistently*
        # failing poll used to be invisible: positions would quietly stop
        # advancing with nothing in the log. Swallow as before, but say so —
        # only on a change of state, so a flapping receiver can't spam the log.
        # #48: waits on the Event handed in BY VALUE, not self.status_stop — a
        # reconnect swaps in a fresh Event, so this cycle can be stopped without
        # a set()->clear() race leaving it looping alongside the new poll thread.
        failing = False
        while not stop.wait(5):
            try:
                if self.cast and self.cast.media_controller.status.player_state in (
                        "PLAYING", "BUFFERING"):
                    self.cast.media_controller.update_status()
                if failing:
                    dbg("poll recovered")
                    failing = False
            except Exception as e:
                if not failing:
                    dbg(f"poll failing: {type(e).__name__}: {e}")
                    failing = True

    # -- ops --------------------------------------------------------------
    def connect(self, dev_id):
        if self.cast and self.cast_id == dev_id:
            return
        # Build and HANDSHAKE the new receiver BEFORE tearing down the current
        # one. The old code disconnected first, so if the new device was
        # unreachable (wait() times out) the working cast was already dead and
        # there was nothing to fall back to. Now the old cast keeps playing
        # until the new one has actually answered.
        info = self.devices.get(dev_id)
        if info:
            new = pychromecast.get_chromecast_from_cast_info(info, self.zconf)
        elif dev_id in self.known:
            # Not currently announcing — dial its last known IP directly.
            d = self.known[dev_id]
            new = pychromecast.get_chromecast_from_host(
                (d["ip"], 8009, dev_id, d.get("model", ""), d["name"]))
        else:
            raise RuntimeError("unknown device")
        try:
            new.wait(timeout=10)      # raises if the device never answered
        except Exception:
            try:
                new.disconnect(timeout=1)   # don't leak the failed attempt
            except Exception:
                pass
            raise
        self.disconnect()             # new device confirmed — now drop the old
        self.cast = new
        self.cast.media_controller.register_status_listener(self)
        self.cast_id = dev_id
        # #48: a fresh stop Event per poll cycle, captured by value in the thread.
        # disconnect() above already .set() the OLD event, so the old poll thread
        # (holding that event) exits; the reused-and-cleared shared event used to
        # let it wake after the clear and keep looping — a leaked second thread.
        stop = threading.Event()
        self.status_stop = stop
        threading.Thread(target=self._poll, args=(stop,), daemon=True).start()

    def disconnect(self):
        self.status_stop.set()
        self.sess = None
        if self.cast:
            # Quit the receiver app FIRST (needs the live connection) so the TV
            # drops to home clean instead of leaving a lingering session that
            # wedges. Belt-and-suspenders with the "stop" op: a teardown can
            # arrive through either path — output switched back to this machine,
            # a device switch, or codec closing.
            try:
                self.cast.quit_app(timeout=3)
            except Exception:
                pass
            try:
                self.cast.disconnect(timeout=3)
            except Exception:
                pass
        self.cast = None
        self.cast_id = ""

    def _rescue_volume(self):
        # A receiver session at volume 0 is indistinguishable from broken
        # audio on the couch — nudge it to something audible.
        try:
            if self.cast.status and (self.cast.status.volume_level or 0) < 0.05:
                self.cast.set_volume(0.30)
        except Exception:
            pass

    def _peer(self):
        info = self.devices.get(self.cast_id)
        if info:
            return str(info.host)
        d = self.known.get(self.cast_id)
        return d["ip"] if d else None

    def _emit_tracks(self):
        s = self.sess
        if not s:
            return
        send({"event": "tracks", "audio": s["audio"], "subs": s["subs"],
              "aidx": s["aidx"], "sub": s["sub"], "mode": s["mode"],
              "yt": bool(s.get("ytvid")),
              "subs_final": bool(s.get("subs_final", True))})

    def _fetch_yt_captions(self, sess):
        """Background: ask the hub which caption languages exist, then
        surface them as the session's sub tracks."""
        try:
            import urllib.request
            data = json.loads(urllib.request.urlopen(
                f"{sess['base']}/ytsubs?v={sess['ytvid']}", timeout=60).read())
            subs = []
            for i, c in enumerate(data.get("subs") or []):
                subs.append({"i": i, "codec": "vtt", "lang": c["lang"],
                             "title": "auto-generated" if c.get("auto") else "",
                             "text": False})  # burned by the lane -> warn on toast
            if self.sess is sess:
                sess["subs"] = subs
                sess["subs_final"] = True
                # Attached sessions: reflect the lane's burned caption track
                # so remote UI and any rebuild agree with what's on screen.
                want = sess.pop("want_cc", "")
                if want and sess["sub"] < 0:
                    for i, t in enumerate(subs):
                        if t["lang"] == want:
                            sess["sub"] = i
                            break
                # Duration rides along so lane restarts hand the TV a real
                # seekable timeline (the initial lane starts without one).
                sess["duration"] = sess["duration"] or data.get("duration") or 0
                # Raw watch-URLs masquerading as titles get the real name.
                real = data.get("title") or ""
                low = (sess["title"] or "").lower()
                if real and ("watch?v" in low or low.startswith("http")
                             or low in ("", "youtube")):
                    sess["title"] = real
                    send({"event": "title", "title": real})
                self._emit_tracks()
        except Exception:
            if self.sess is sess:
                sess["subs_final"] = True  # truthful "none found" beats limbo
                self._emit_tracks()

    def _yt_lane(self, start):
        """Stream the YouTube video through the hub (captions burned when a
        track is selected) — the native receiver has no CC control at all."""
        s = self.sess
        s.pop("lane_url", None)
        # Roaming: refresh the browse token into base on every (re)start so a
        # reload after a 403 rebuilds the Funnel URL with a live token (see
        # _recover); browse_token() is cached, so a no-op on the happy path.
        if s.get("roam_yt"):
            tok = browse_token()
            if tok:
                s["base"] = f"{hub_funnel()}/r/{tok}"
        cc = ""
        if 0 <= s["sub"] < len(s["subs"]):
            cc = s["subs"][s["sub"]]["lang"]
        s["lane"] = True
        s["owner"] = True  # we drive this lane -> our watchdog's job
        # HLS even when duration is still unknown (initial loads race the
        # async yt-dlp fetch) — the hub self-resolves dur for the playlist,
        # so the FIRST lane already has a real seekable timeline. The piped
        # lane survives only as the no-HLS-hub fallback.
        if s.get("roam_yt") or hub_has_hls(s["base"]):
            s["offset"] = 0.0
            s["hls"] = True
            # A dur-less yt HLS lane is either live or dur-not-yet-known; confirm
            # LIVE so the receiver plays at the edge (no scrubber, no seek-into-
            # -live) and the hub serves its rolling live-restream lane. A real
            # VOD is never is_live, so this can't mislabel one.
            live = (not s["duration"]) and hublib.yt_is_live(s["ytvid"])
            s["is_live"] = live
            # A VOD clip queued without a duration (a party advance hands the item
            # over with none) — resolve it so the receiver's total-time is THIS
            # clip's, not the previous cast's carried-over value (the "2:04:01 on a
            # 4-minute clip" after a DV -> yt party advance).
            if not live and not s["duration"]:
                try:
                    s["duration"] = float(
                        hublib.yt_info(s["ytvid"]).get("duration") or 0)
                except Exception:
                    pass
            data = {"media_id": (f"{s['base']}/hls/pl.m3u8?kind=yt&v={s['ytvid']}"
                                 f"&cc={cc}&subsize={s.get('subsize', 1.0):g}&substyle={quote(cap_style_token(), safe='')}"
                                 f"&dur={s['duration'] or 0:.3f}"
                                 f"&warm={int(start // 4)}"),
                    "media_type": "application/vnd.apple.mpegurl",
                    "title": s["title"],
                    "stream_type": "LIVE" if live else "BUFFERED"}
            s["lane_url"] = data["media_id"]     # what _hls_prewarm re-warms
            if not live:
                data["media_info"] = {"duration": s["duration"]}
                if start > 0:
                    data["current_time"] = start
            # The receiver's #tbar total-time reads customData.fullDur — set it
            # EXPLICITLY (0 for live) so a party advance onto this item resets it
            # instead of inheriting the previous cast's duration.
            data.setdefault("media_info", {}).setdefault(
                "customData", {})["fullDur"] = 0 if live else (s["duration"] or 0)
        else:
            s["offset"] = start
            s["hls"] = False
            data = {"media_id": (f"{s['base']}/ytstream?v={s['ytvid']}"
                                 f"&start={start:.3f}&cc={cc}"
                                 f"&subsize={s.get('subsize', 1.0):g}&substyle={quote(cap_style_token(), safe='')}"
                                 f"&dur={max(0.0, (s['duration'] or 0) - start):.3f}"),
                    "media_type": "video/mp4", "title": s["title"],
                    "stream_type": "BUFFERED"}
            if s["duration"]:
                data["media_info"] = {
                    "duration": max(0.0, s["duration"] - start)}
        if s["thumb"]:
            data["thumb"] = thumb_url(s["thumb"], s.get("base") or "")
        self._mark_lane_start()
        s["media_id"] = data["media_id"]
        dbg(f"yt_lane load {data.get('media_id', '')[:200]}")
        # No manifest entry for a YouTube video, but it has its own thumbnail
        # and that is the art the card should wear.
        card_into(data, s, art_url=s["thumb"] or "")
        cast_load(self.cast, data)
        self.last_pos = start
        self._emit_tracks()

    def _hls_prewarm(self, s, position):
        """Re-fetch the playlist with warm=<target segment>: the hub restarts
        its encoder there immediately instead of when the TV finally asks.

        `s` here is a FROZEN key snapshot taken under lock by seek() (#21), NOT the
        live session dict — do not swap it back for self.sess, or a concurrent
        set_audio/set_sub can shift aidx/sub and reap the live encoder."""
        try:
            import urllib.request
            # Must hit the EXACT live session key (cc/burn included) — a
            # mismatched key would evict the active session's encoder. The lane
            # URL the TV was given is that key, so re-warm it with only warm=
            # changed. (Rebuilding it here drifted: text subs now SIDELOAD, so
            # the live lane says burn=-1 while a rebuild said burn=<track> — a
            # new session whose encoder reaped the TV's on every seek.) It is
            # sent as a Cast client, as the TV is, so the hub sizes the same
            # rungs (it caps a Cast client's ladder at 1080).
            if s.get("lane_url"):
                url = re.sub(r"([?&]warm=)\d+", rf"\g<1>{int(position // 4)}",
                             s["lane_url"])
                urllib.request.urlopen(urllib.request.Request(
                    url, headers={"CAST-DEVICE-CAPABILITIES": "{}"}),
                    timeout=10).read()
                dbg(f"prewarm seg {int(position // 4)}")
                return
            sel = 0 <= s.get("sub", -1) < len(s.get("subs") or [])
            if s.get("ytvid"):
                cc = s["subs"][s["sub"]]["lang"] if sel else ""
                url = (f"{s['base']}/hls/pl.m3u8?kind=yt&v={s['ytvid']}"
                       f"&cc={cc}&subsize={s.get('subsize', 1.0):g}&substyle={quote(cap_style_token(), safe='')}"
                       f"&dur={s['duration']:.3f}&warm={int(position // 4)}")
            else:
                burn = s["subs"][s["sub"]]["i"] if sel else -1
                url = (f"{s['base']}/hls/pl.m3u8?src={quote(s['src'], safe='')}"
                       f"&aidx={s['aidx']}&burn={burn}&mode=fit"
                       f"&subsize={s.get('subsize', 1.0):g}&substyle={quote(cap_style_token(), safe='')}&v={s['video']}"
                       f"&dur={s['duration']:.3f}&warm={int(position // 4)}")
            urllib.request.urlopen(url, timeout=10).read()
            dbg(f"prewarm seg {int(position // 4)}")
        except Exception:
            pass

    def _mark_lane_start(self):
        self.pending_seek = None
        self.buf_since = None
        self.had_played = False
        self.lane_started_at = time.time()
        self.frozen_pos = None
        self.frozen_since = 0.0

    def _warm_subs(self, sess):
        """Background: ask the lane host to pre-extract text sub tracks so a
        later toggle starts instantly (UHD remuxes take minutes to extract)."""
        import urllib.request
        for t in [t for t in sess["subs"] if t.get("text")][:3]:
            try:
                urllib.request.urlopen(
                    f"{sess['base']}/subready?src={quote(sess['src'], safe='')}"
                    f"&i={t['i']}", timeout=10).read()
            except Exception:
                pass

    def _sub_ready(self, track):
        """True when this track can be shown instantly. Asking first keeps a
        not-yet-extracted (text) or not-yet-OCR'd (bitmap) track from making the
        overlay sit blank while the hub works — the caller shows 'preparing'."""
        s = self.sess
        # i < 0 is a SIDECAR file already sitting on disk beside the movie —
        # nothing to prepare, and asking /subready about a negative index would
        # index the codec list from the wrong end. Both TEXT (extract) and BITMAP
        # (OCR) embedded tracks otherwise go through the hub's readiness check.
        if track.get("i", 0) < 0 or s.get("ytvid"):
            return True
        try:
            import urllib.request
            if s.get("roam"):
                # the token surface says per track; it kicks the prep only for
                # the preferred track, so an unready OTHER track is kicked by
                # asking for it (the hub answers 503 and starts the extract/OCR)
                d = json.loads(urllib.request.urlopen(
                    f"{s['rbase']}/subs?i={s['ridx']}", timeout=8).read())
                for t in d.get("subs") or []:
                    if t.get("i") == track["i"]:
                        ready = bool(t.get("ready", True))
                        if not ready:
                            try:
                                urllib.request.urlopen(
                                    f"{s['rbase']}/sub?i={s['ridx']}&t={track['i']}",
                                    timeout=5).close()
                            except Exception:
                                pass
                        return ready
                return True
            r = json.loads(urllib.request.urlopen(
                f"{s['base']}/subready?src={quote(s['src'], safe='')}"
                f"&i={track['i']}", timeout=5).read())
            return bool(r.get("ready", True))
        except Exception:
            return True  # can't tell — keep old behavior

    def _sub_track(self):
        s = self.sess
        if s["sub"] < 0 or s["sub"] >= len(s["subs"]):
            return None
        return s["subs"][s["sub"]]

    def _device_model(self):
        info = self.devices.get(self.cast_id)
        if info is not None:
            return getattr(info, "model_name", "") or ""
        d = self.known.get(self.cast_id)
        return (d or {}).get("model", "") if d else ""

    def _roam_pick(self, rbase, idx, cap_w):
        """The width-capped ADAPTIVE master for this receiver. `&maxw=cap_w`
        tells the hub our decoder ceiling, so every rung it lists is ≤ cap_w —
        the device can decode any of them and rides the ladder up and down with
        the real throughput of the foreign wifi: a dip steps it DOWN a rung
        instead of stalling. Returns (media_id, adaptive=True).

        This used to fetch the master and hand back a single budget-capped
        (~480p) rung, because the un-capped master listed native-width rungs the
        device errored on rather than adapting past — so a single fixed rung was
        the only safe choice, and with no lower fallback a wifi dip stalled it
        hard. Now that the hub caps the ladder by WIDTH (commit 173f6bd,
        deployed), the receiver can be trusted with the whole master and does
        its own ABR — strictly better than one fixed rung, and it lifts the old
        480p ceiling to a true 1080p-class top rung. No worker-side fetch: the
        receiver pulls the master itself (as ABR requires), which also drops a
        45s-timeout round trip off the cast-start path."""
        return f"{rbase}/hls/pl?i={idx}&maxw={cap_w}", True

    def _roam_subs(self, rbase, idx):
        """The title's text sub tracks, from the browse surface (index-keyed).
        Empty on any failure — a movie without subs still casts."""
        try:
            import urllib.request
            d = json.loads(urllib.request.urlopen(
                f"{rbase}/subs?i={idx}", timeout=20).read())
            return [{"i": t["i"], "codec": "vtt", "lang": t.get("lang", ""),
                     "title": t.get("title", ""), "text": True}
                    for t in (d.get("subs") or [])]
        except Exception as e:
            # A movie with no subs still casts — but distinguish "none exist"
            # (empty subs list above) from "the fetch TIMED OUT over the slow
            # link". The latter silently dropped ALL tracks for the session;
            # tell the user so they know subtitles were lost to a hiccup, not
            # absent, and can recast to get them back.
            dbg(f"_roam_subs failed: {e}")
            send({"event": "cast_error",
                  "error": "couldn't load subtitles over this link — casting "
                           "without them; recast to try again"})
            return []

    def _roam_verify(self, rbase, idx, want_title):
        """Confirm the hub resolves this manifest index to the title we expect.
        The index is computed against the satellite's LOCAL manifest copy; if
        that has drifted from the hub's live manifest (a re-export the satellite
        hasn't pulled), index N points at a DIFFERENT title on the hub, and
        casting it would silently play the wrong movie. Returns True on a match
        or when it can't be checked; False only on a confirmed mismatch."""
        want = (want_title or "").strip().lower()
        if not want:
            return True
        try:
            import urllib.request
            d = json.loads(urllib.request.urlopen(
                f"{rbase}/detail?i={idx}", timeout=15).read())
        except Exception:
            return True   # can't verify (transient) — don't block the cast
        got = (d.get("title") or "").strip().lower()
        return not got or got == want

    def _roam_load(self, uri, req):
        """Cast a hub library title from a foreign network over Funnel. Reuses
        the browse link's token-scoped, manifest-index HLS surface — nothing
        here ever names a filesystem path. Default audio; text subs ride as a
        real Cast track the TV renders itself."""
        # Away-from-home start serializes several blocking round trips over a
        # slow foreign link (tailscale status + token mint + subs fetch) before
        # the receiver gets a URL — up to ~30s of dead air. Say what's happening
        # so it doesn't read as a freeze (the friend's-house failure mode).
        send({"event": "cast_error",
              "error": "casting from away — connecting to the hub, one moment…"})
        pub, tok, idx = hub_public_base(), browse_token(), manifest_index(uri)
        if not pub or not tok or idx < 0:
            why = (("the hub's public door doesn't answer from this network"
                    if hub_funnel() else "Funnel origin isn't configured (hubFunnel)")
                   if not pub
                   else "couldn't reach the hub to authorize the stream"
                   if not tok else "this title isn't in the synced library")
            send({"event": "cast_error",
                  "error": f"can't cast away from home — {why}"})
            return
        rbase = f"{pub}/r/{tok}"
        want_title = req.get("title") or Path(urlparse(uri).path).stem
        # Guard the silent-wrong-movie case before anything starts playing.
        if not self._roam_verify(rbase, idx, want_title):
            send({"event": "cast_error",
                  "error": "can't cast — your library is out of sync with the "
                             "hub; reopen codec to refresh, then try again"})
            return
        dur = float(req.get("duration") or 0)
        # The hub's own ffprobe of the title (duration, audio + subtitle tracks,
        # video codec) — the LAN cast's probe, over the token surface. Audio
        # switching and the DASH lane's aidx need the track list.
        info = {}
        try:
            import urllib.request
            info = json.loads(urllib.request.urlopen(
                f"{rbase}/probe?i={idx}", timeout=25).read()) or {}
        except Exception as e:
            dbg(f"roam probe failed: {e}")
        if not dur and info.get("duration"):
            dur = float(info["duration"])
        audio = list(info.get("audio") or [])
        subs = self._roam_subs(rbase, idx)
        aidx0 = _choose_audio(audio, _library_rel(uri) or uri) if audio else 0
        self.sess = {
            "uri": uri, "roam": True, "ridx": idx, "rbase": rbase,
            "base": rbase, "src": uri,
            "title": want_title,
            "thumb": "", "duration": dur, "video": info.get("video") or "",
            "safe": False,
            "audio": audio, "subs": subs, "aidx": aidx0, "sub": -1, "mode": "fit",
            "vtt": -1, "offset": 0.0, "lane": True, "hls": True, "owner": True,
            "subsize": float(req.get("subsize") or 1.0), "subs_final": True,
        }
        # A fresh cast starts its clocks fresh: the "no picture in 45 s" clock
        # used to survive from the LAST roaming cast and stepped the next one
        # down at its first buffering tick. A wedge heal re-issuing the same
        # load keeps it (and the ladder verdict, if there was one).
        if not req.get("_keep_clock"):
            self.roam_dash_since = 0.0
        if req.get("force_ladder"):
            self.sess["force_ladder"] = True
        alang = audio[aidx0].get("lang") if 0 <= aidx0 < len(audio) else None
        fsub = _forced_sub(subs, alang)        # -1 when the film has none
        if fsub >= 0:
            self.sess["sub"] = fsub
        else:
            for i, t in enumerate(subs):  # default to English if present
                if t.get("lang") in ("eng", "en"):
                    self.sess["sub"] = i
                    break
        self._start_stream(float(req.get("position") or 0))
        self._rescue_volume()
        self._emit_tracks()

    def _start_roam_stream(self, start):
        """The roaming counterpart to _start_stream: the width-capped adaptive
        HLS master off the browse surface, keyed by manifest index, with the
        selected text sub sideloaded. The receiver scrubs its own timeline and
        adapts its own bitrate off the ladder."""
        s = self.sess
        # Refresh the token into rbase on every (re)start. browse_token() is
        # cached, so this is a no-op on the happy path; but a recovery clears
        # that cache first (see _recover), so a reload after a 403 rebuilds the
        # URL with a LIVE token instead of the dead one baked into the session.
        tok = browse_token()
        if tok:
            s["rbase"] = f"{hub_public_base()}/r/{tok}"
        rbase, idx = s["rbase"], s["ridx"]
        cap_w = _cap_width(self._device_model())
        sub = self._sub_track()
        s.pop("hdr_cast", None)
        s["dash_cast"] = False
        s["dv_lane"] = False
        self.roam_buf = []
        self.roam_tick = 0.0
        # ── the same lane the LAN cast gets (#219, over the token surface) ──
        # Ask the hub which lane it will serve this title: Dolby Vision copy,
        # HDR10 transcode, or the ladder. A DV title at a friend's house used
        # to ride the SDR ladder only — the lanes the party guests got over the
        # fast road are what a solo cast from away gets now. Same URL params
        # the LAN worker sends /hls/pl, keyed by index instead of path; the
        # receiver's DASH path (DV_LANE re-warm, hdrType, MSEBASE) is unchanged.
        dec = None
        if s.get("force_ladder"):
            # the link starved the full-quality lane earlier in this cast
            # (_roam_starved): the adaptive ladder for the rest of it
            dbg("roam: ladder forced for this cast (lane starved earlier)")
        else:
            try:
                import urllib.request
                dec = json.loads(urllib.request.urlopen(
                    f"{rbase}/hls/preflight?i={idx}&aidx={s['aidx']}&burn=-1",
                    timeout=12).read())
            except Exception as e:
                dbg(f"roam preflight failed ({e}) -> ladder")
        if dec and isinstance(dec.get("dvGoal"), int):
            s["dv_goal"] = dec["dvGoal"]
        if dec and dec.get("fmt") == "dash":
            CAST_SEG = hublib.CAST_SEG
            hwarm = max(0, int((start - 2.5) // CAST_SEG))
            durl = (f"{rbase}/hls/pl?i={idx}"
                    f"&aidx={s['aidx']}&mode=fit&v={s['video']}"
                    f"&hevc=1&hdr={1 if dec['hdr'] else 0}"
                    f"&sdr={0 if dec['hdr'] else 1}&maxw=3840&kind=file"
                    f"&dur={s['duration'] or 0:.3f}"
                    f"&warm={hwarm}&fmt=dash"
                    + ("&dv=1" if dec["dv"] else "&dv=0"))
            data = {"media_id": durl, "media_type": "application/dash+xml",
                    "title": s["title"], "stream_type": "BUFFERED",
                    "media_info": {
                        "duration": s["duration"],
                        "customData": {
                            "dash": True, "hdr": dec["hdr"], "streamUrl": durl,
                            "resumeOffset": 0,
                            "dvWarm": (start if dec["dv"] and start > 0 else 0),
                            "fullDur": s["duration"] or 0}}}
            s["hdr_cast"] = True
            s["dash_cast"] = True
            s["dv_lane"] = bool(dec.get("dv"))
            if not self.roam_dash_since:
                self.roam_dash_since = time.time()   # the "no picture in 45 s" clock
            if start > 0:
                data["current_time"] = start
            # text subs hand-render on the receiver's own overlay (MGS face,
            # HDR-safe), as on the LAN DASH lane — never a CAF caption track.
            # Only a track the hub has READY: the overlay's one fetch of a cold
            # track is a 503 it never retries (the LAN /subs blocks until the
            # extract is done; the token surface doesn't). Asking readiness
            # kicks the prep, so the next SUBS press lands it.
            if sub and sub.get("text") and self._sub_ready(sub):
                data["media_info"]["customData"]["capUrl"] = self._cap_url(sub)
                s["vtt"] = sub["i"]
            else:
                s["vtt"] = -1
            data["media_info"]["customData"]["capStyle"] = cap_style()
            lane_word = "dv" if dec["dv"] else "hdr10"
        else:
            media_id, adaptive = self._roam_pick(rbase, idx, cap_w)
            data = {"media_type": "application/vnd.apple.mpegurl",
                    "title": s["title"], "stream_type": "BUFFERED",
                    "media_id": media_id}
            if s["duration"]:
                data["media_info"] = {"duration": s["duration"]}
            if start > 0:
                data["current_time"] = start
            # the overlay here too (one face — this used to be a CAF text
            # track in CAF's own SANS, and a cold track started blank); the
            # receiver retries a 503 itself now, and asking readiness kicks
            # the hub's prep
            cdl = data.setdefault("media_info", {}).setdefault("customData", {})
            cdl["capStyle"] = cap_style()
            if sub and sub.get("text"):
                self._sub_ready(sub)
                cdl["capUrl"] = self._cap_url(sub)
                s["vtt"] = sub["i"]
            else:
                s["vtt"] = -1
            lane_word = "ladder"
            self.roam_dash_since = 0.0
        s["media_id"] = data["media_id"]
        self._mark_lane_start()
        dbg(f"roam load i={idx} lane={lane_word} capw={cap_w} aidx={s['aidx']} "
            f"sub={s['sub']} {str(data['media_id'])[:200]}")
        card_into(data, s)
        cast_load(self.cast, data)
        self.last_pos = start

    def _start_stream(self, start):
        """(Re)start the receiver stream honoring the session's track/mode
        state. Direct when possible (absolute clock keeps sideloaded subs
        aligned); the lane when audio/codec/mode/burn require it."""
        s = self.sess
        s.pop("lane_url", None)      # set again below only by the SDR ladder
        if s.get("roam"):
            return self._start_roam_stream(start)
        sub = self._sub_track()
        burn = -1
        sideload = None
        # Zoom no longer forces an encoded lane: it's a receiver-side transform,
        # so a direct/copy play stays direct and the picture is scaled on the TV.
        needs_lane = (not s["safe"]) or s["aidx"] != 0
        if sub:
            # TEXT subs ride as a real Cast track the TV renders itself; only
            # BITMAP subs (PGS/dvdsub) still burn, because there is no text to
            # send and an image track is not a thing Cast has.
            #
            # Burning everything was a workaround for a bug, not a decision:
            # sideloading looked broken because /subs answered without an
            # Access-Control-Allow-Origin header, so the receiver fetched the
            # VTT and silently discarded it. Burning costs real things — it
            # forces a re-encode (so a direct-playable file stops being
            # direct-playable), it forces CPU filters (which drags frames off
            # the GPU and halves the ladder's throughput), and above all it
            # forces SDR, because there is no correct brightness for white
            # text composited into a PQ frame: at full code value it is a
            # 1000-nit glare. A real text track is rendered by the TV at
            # display brightness, so HDR and subtitles finally coexist.
            #
            # ⚠ Only where receiver time IS file time: direct play, and the
            # HLS lane (whose playlist covers the whole timeline). The legacy
            # PIPED lane restarts its clock at the seek point, so a VTT with
            # absolute timings would run `start` seconds out — there, burning
            # is still the honest answer.
            # TEXT subs sideload as-is; BITMAP (PGS/dvdsub) subs are OCR'd to text
            # by the hub's /subs (pgsrip, offline; external-SRT fallback) so they
            # hand-render and KEEP DV instead of burning. Both need receiver-time
            # == file-time (direct play or the HLS lane); only the legacy PIPED
            # lane's clock mismatch still forces a burn.
            if not needs_lane or hub_has_hls(s["base"]):
                sideload = sub
            else:
                burn = sub["i"]
                needs_lane = True

        # BUFFERED (pychromecast defaults to LIVE!) + a real duration give the
        # TV a seekable timeline — its own remote can scrub; the lane
        # watchdog recovers seeks that land outside the buffered window.
        data = {"media_type": "video/mp4", "title": s["title"],
                "stream_type": "BUFFERED"}
        if s["thumb"]:
            # thumb_url, as the YouTube and party paths do: a library poster is
            # a LOCAL path, which the TV's own overlay cannot fetch.
            t = thumb_url(s["thumb"], s.get("base") or "")
            if t:
                data["thumb"] = t
        # One place to build a hub URL for THIS source (#223): the ?src=quote(...)
        # prefix was hand-repeated at every lane AND the subtitle builder. Defined
        # here (not inside `if needs_lane`) so the sideload-subs block below can use
        # it too. Each lane still appends its own distinct params — they are
        # genuinely different endpoints (/hls/pl dash, /hls/pl.m3u8 ladder,
        # /transcode piped, /subs).
        mk = lambda path: f"{s['base']}/{path}?src={quote(s['src'], safe='')}"
        if needs_lane:
            s["lane"] = True
            s["owner"] = True  # we drive this lane -> our watchdog's job
            if hub_has_hls(s["base"]):
                # HLS lane: the playlist declares the WHOLE timeline, so the
                # receiver shows a real bar and its own remote scrubs — any
                # seek is a plain absolute seek, the hub encoder follows.
                s["offset"] = 0.0
                s["hls"] = True
                # HDR source → the DASH-via-CAF path = TRUE 4K HDR cast. CAF's
                # native cast-media-player decodes HEVC via MediaCodec straight
                # onto an HDR surface, which composites a real BT2020_ITU_PQ
                # HDR10 layer on the Bravia (verified over ADB, 2026-08-23). The
                # old HLS/TS lane below can only carry h264 here, so it TONE-MAPS
                # to SDR — correct, but not HDR. Burning subs forces SDR (no
                # right brightness for text in a PQ frame), so that stays on HLS.
                # ── ONE lane authority (#219) ────────────────────────────────
                # Ask the hub which lane it will serve. It probes the REAL file
                # (video_info + dv_probe) and is the single source of truth. The
                # worker USED TO guess DV/HDR/4K from filename tokens + the quality
                # label; that guess diverged from what the hub actually served and
                # set the receiver's DV_LANE / hdrType from the wrong side → DV
                # seek freezes (DV file, no filename token → DV_LANE off → the
                # open-GOP re-warm protection never armed) and spurious re-warms
                # (non-DV file with a "dv" token → DV_LANE on over HDR10). dec.fmt
                # already folds in NVENC + burn<0, so we never request the GPU dash
                # lane the hub can't run. On any preflight failure dec is None →
                # fall through to the SDR ladder below (universally castable).
                #
                # The GPU dash lane is TRUE 4K HDR: CAF's native cast-media-player
                # decodes HEVC via MediaCodec onto an HDR surface (BT2020_ITU_PQ,
                # verified over ADB). Both dash lanes (DV copy + HDR10 transcode)
                # carry an ABSOLUTE film-time timeline, so current_time=start below
                # lands the resume point on either. The manifest's codec string
                # (dvh1 vs hev1) is what arms the panel's DV vs HDR10 decoder.
                dec = hub_preflight(s["base"], s["src"], s["aidx"], burn)
                # Stash the hub's per-title forward-buffer size on the SESSION
                # (this scope has `s`, not the op dict) so the customData builder
                # can carry it to the receiver — see dv_buffer_goal server-side.
                if dec and isinstance(dec.get("dvGoal"), int):
                    s["dv_goal"] = dec["dvGoal"]
                if dec and dec.get("fmt") == "dash":
                    # The GPU per-segment cast lane uses CAST_SEG-second segments
                    # (longer than the 4s ladder default → snappier seeks). The warm
                    # point must be computed on the SAME grid the serve cuts on, or
                    # seg numbers mismatch — so take the hub's own constant (#222),
                    # never a hand-synced literal. Routes 4K HDR AND heavy 4K SDR
                    # HEVC (#202) here; the receiver only sets HDR mode when hdr=True.
                    CAST_SEG = hublib.CAST_SEG
                    # Start the muxer >=2.5s BEFORE the resume point. ffmpeg's -ss
                    # copy makes v0/seg1 a lead-in GOP the manifest doesn't count, so
                    # a boundary-exact resume makes CAF under-fetch into the DV lane's
                    # placeholder head -> 404 loop -> IDLE. Backing off the 6s grid by
                    # 2.5s keeps the join out of the head. current_time=start still
                    # lands at start; copy is ~50x realtime so the lead-in is free.
                    hwarm = max(0, int((start - 2.5) // CAST_SEG))
                    durl = mk("hls/pl") + (
                        f"&aidx={s['aidx']}&mode=fit&v={s['video']}"
                        f"&hevc=1&hdr={1 if dec['hdr'] else 0}"
                        f"&sdr={0 if dec['hdr'] else 1}&maxw=3840&kind=file"
                        f"&dur={s['duration'] or 0:.3f}"
                        f"&warm={hwarm}&fmt=dash"
                        # Explicit &dv=1/&dv=0 from the hub's decision — never the
                        # filename. &dv=0 keeps the receiver's DV_LANE off on HDR10.
                        + ("&dv=1" if dec["dv"] else "&dv=0"))
                    data["media_id"] = durl
                    data["media_type"] = "application/dash+xml"
                    data["media_info"] = {
                        "duration": s["duration"],
                        "customData": {
                            "dash": True, "hdr": dec["hdr"], "streamUrl": durl,
                            # Both lanes now carry an ABSOLUTE full-movie timeline and
                            # land at the resume point via current_time=start (below),
                            # so resumeOffset is 0 and EITHER remote can scrub BEFORE
                            # the resume point. dvWarm is the DV lane's resume point
                            # (film s): its copy segments exist only from there forward
                            # (one -ss run), so the receiver re-warms the lane on a
                            # scrub before it (rewarmTo). Harmless (0) on the HDR10
                            # lane, which can produce any segment on demand, and on a
                            # fresh play.
                            "resumeOffset": 0,
                            "dvWarm": (start if dec["dv"] and start > 0 else 0),
                            "fullDur": s["duration"] or 0}}
                    s["hdr_cast"] = True
                    # Per-segment dash lane marker (DV copy OR HDR10/heavy-4K-SDR
                    # HEVC transcode). seek() skips _hls_prewarm on ANY dash lane:
                    # the prewarm URL (pl.m3u8?warm=pos//4, no &fmt=dash) hashes to a
                    # DIFFERENT hub session whose hls_ensure_encoder calls
                    # hls_stop_others() and REAPS this live lane's seg_jobs+audio on
                    # every seek. This lane makes any segment on demand, so the native
                    # seek alone is right (the receiver rebuilds nothing off DV).
                    s["dash_cast"] = True
                    # DV copy lane marker (Phase A): seek() must treat this lane
                    # specially — the receiver SWALLOWS a far/head seek to re-warm
                    # itself, so a blocking native seek here would stall the single
                    # command loop the full 10 s and freeze reactive recovery.
                    s["dv_lane"] = bool(dec.get("dv"))
                    # Land the initial playback at the resume point via current_time.
                    # BOTH lanes now carry an ABSOLUTE film-time timeline (the DV lane
                    # prepends a placeholder head for [0, warm) + shifts each segment's
                    # tfdt up by warm·ts — serve dv_dash_manifest / the seg handler), so
                    # a current_time=start seek is right for DV too: it lands at the
                    # resume point AND the TV's own transport bar reads true film time.
                    if start > 0:
                        data["current_time"] = start
                else:
                    # SDR ladder. The receiver takes h264-in-TS (up to native
                    # 4K); the hub tone-maps the HDR source properly on the way
                    # (correct BT.2390, not PQ-relabelled-bt709).
                    data["media_id"] = mk("hls/pl.m3u8") + (
                        f"&aidx={s['aidx']}&burn={burn}&mode=fit"
                        f"&subsize={s.get('subsize', 1.0):g}&substyle={quote(cap_style_token(), safe='')}&v={s['video']}"
                        f"&sdr=1"
                        f"&dur={s['duration'] or 0:.3f}&warm={int(start // 4)}")
                    s["lane_url"] = data["media_id"]   # what _hls_prewarm re-warms
                    data["media_type"] = "application/vnd.apple.mpegurl"
                    data["media_info"] = {"duration": s["duration"]}
                    if start > 0:
                        data["current_time"] = start
            else:
                # Piped-lane fallback (old hub / unknown duration): receiver
                # time is segment-relative, file time = offset + receiver.
                s["offset"] = start
                s["hls"] = False
                if s["duration"]:
                    data["media_info"] = {
                        "duration": max(0.0, s["duration"] - start)}
                data["media_id"] = mk("transcode") + (
                    f"&start={start:.3f}&v={s['video']}&aidx={s['aidx']}"
                    f"&burn={burn}&mode=fit"
                    f"&subsize={s.get('subsize', 1.0):g}&substyle={quote(cap_style_token(), safe='')}"
                    f"&dur={max(0.0, (s['duration'] or 0) - start):.3f}")
        else:
            s["offset"] = 0.0
            s["lane"] = False
            data["media_id"] = s["direct_url"]
            data["media_type"] = content_type(s["uri"])
            if s["duration"]:
                data["media_info"] = {"duration": s["duration"]}
            if start:
                data["current_time"] = start
        # TEXT subs hand-render on the receiver (own #cap overlay: MGS font,
        # zoom-immune, HDR-safe) instead of CAF's caption layer. The VTT url rides
        # customData so a seek-rewarm keeps subtitles; set_sub swaps it live via
        # SubController. (Bitmap subs still burn into the video, upstream.)
        cap_url = (mk("subs") + f"&i={sideload['i']}") if sideload else None
        if cap_url:
            data.setdefault("media_info", {}).setdefault(
                "customData", {})["capUrl"] = cap_url
        # the caption face (font / colour / size / box) — this machine's cast
        # caption settings, so a satellite's reach the TV; live changes ride
        # the sub channel (sub_style)
        data.setdefault("media_info", {}).setdefault(
            "customData", {})["capStyle"] = cap_style()
        s["vtt"] = sideload["i"] if sideload else -1
        s["media_id"] = data["media_id"]
        self._mark_lane_start()
        dbg(f"stream load hls={s.get('hls')} lane={s['lane']} "
            f"{str(data.get('media_id'))[:200]}")
        card_into(data, s)
        cast_load(self.cast, data)
        self.last_pos = start
        self._rescue_volume()
        self._emit_tracks()

    def _party_subs(self, base, token):
        """The party's offered text tracks, from the room state the web
        follower reads (media.subs = [{i,lang,title,ready}]). Only READY
        tracks: a track offered before its VTT is on disk lands dead in the
        TV's own menu (the sideloaded-subs bug). The hub is the authority here,
        so fetch it rather than trusting the app to have threaded it."""
        try:
            import urllib.request
            st = json.loads(urllib.request.urlopen(
                f"{base}/p/{token}/state", timeout=8).read())
            subs = ((st.get("media") or {}).get("subs")) or []
            return [x for x in subs if x.get("ready") is not False]
        except Exception:
            return []

    def _party_set_sub(self, index):
        """Follower subtitle toggle. The room's text tracks hand-render in the
        receiver's own overlay (one caption face), so picking one is a push of
        its VTT url over the sub channel — never a lane restart (a follower
        owns no lane to re-cut). They used to be CAF text tracks switched by
        EDIT_TRACKS_INFO."""
        s = self.sess
        if not s:
            return
        n = len(s.get("subs") or [])
        if index is None or index < 0 or index >= n:
            s["sub"] = -1
            self._push_sub(None)
        else:
            s["sub"] = index
            self._push_sub(f"{s.get('sub_url', '')}{s['subs'][index].get('i')}")
        self._emit_tracks()

    def _party_follower_load(self, req, token):
        """Point the connected TV at an existing hub party as a FOLLOWER.

        Unlike a normal (solo) cast this builds NO lane of its own: the party
        already publishes one shared lane for the whole room, and the receiver
        pulls it straight from /p/<token>/hls/pl. All this hands over is the
        clock URL and the stream URL in customData; the receiver's own loop
        chases the room from there. The party routes answer on the LAN :8200
        too (codec-serve do_GET), so a TV on the house network reaches them
        directly — no Funnel hop for a cast in the same room."""
        base = hub_base(self._peer())            # http://<lan>:8200 on the hub
        p = f"{base}/p/{token}"
        cd = {"token": token, "solo": False,
              "stateUrl": f"{p}/state", "streamUrl": f"{p}/hls/pl",
              "subUrl": f"{p}/sub?i=",
              # The room-control write endpoint, so the physical TV remote can
              # drive the whole party (pause/seek), not just this receiver. Set
              # ONLY here — a LAN cast, where /party/cmd is reachable and writes
              # are allowed. A remote guest's TV rides the read-only Funnel and
              # gets no cmdUrl, so it can never move someone else's room.
              "cmdUrl": f"{base}/party/cmd",
              # Receiver sync beacons — dormant unless the cast debug flag is
              # set (~/.config/codec/debug), then they log to the hub journal.
              "dbg": DEBUG_FLAG.exists()}
        # The TV's own name for the room's roster ("Bedroom TV 2", not "guest").
        try:
            cd["name"] = (self.cast.cast_info.friendly_name or "TV")[:24]
        except Exception:
            pass
        # Prefer the room state (authoritative + ready-filtered); fall back to
        # whatever the app threaded in. The SAME list feeds the receiver's
        # sideload (cd.subs) and the session below, so a track's ordinal in the
        # app's list == its receiver Track id − 1 == what _party_set_sub selects.
        subs = self._party_subs(base, token)
        if not subs and isinstance(req.get("subs"), list):
            subs = req["subs"]
        sub0 = -1
        if subs:
            cd["subs"] = subs
            # the room's English track (else its first) shows from the start —
            # the receiver used to pick it on its own while this session said
            # OFF, so the first SUBS press on the remote looked dead
            sub0 = next((n for n, t in enumerate(subs)
                         if str(t.get("lang") or "").lower().startswith("en")), 0)
            cd["capUrl"] = cd["subUrl"] + str(subs[sub0].get("i"))
        cd["capStyle"] = cap_style()
        dur = float(req.get("duration") or 0)
        pos = float(req.get("position") or 0)
        stream = f"{p}/hls/pl"
        # quick_play's contract: media_id (the content URL), media_type,
        # stream_type, current_time — NOT the app-side uri/position names. The
        # receiver overrides contentId from customData.streamUrl anyway, but
        # media_id has to be a valid URL for the load to be accepted at all.
        data = {"media_type": "application/vnd.apple.mpegurl",
                "title": req.get("title") or "",
                "stream_type": "BUFFERED",
                "media_id": stream,
                "media_info": {"duration": dur, "customData": cd}}
        thumb = thumb_url(req.get("thumb"), base)
        if thumb:
            data["thumb"] = thumb
        if pos > 0:
            data["current_time"] = pos
        # A minimal session so status polls + the transport controls have a
        # target; the receiver runs the party clock itself, so there is no lane
        # for this worker to own or re-cut.
        self.sess = {"uri": stream, "media_id": stream,
                     "title": data["title"], "duration": dur, "base": base,
                     "party": token, "owner": True, "lane": False, "safe": True,
                     "audio": [], "subs": subs, "aidx": 0, "sub": sub0,
                     "sub_url": cd["subUrl"],
                     "mode": "fit", "vtt": -1, "offset": 0.0}
        dbg(f"party-follower load token={str(token)[:4]}… base={base} "
            f"id={stream} subs={len(subs)}")
        cast_load(self.cast, data)
        self._rescue_volume()
        # Hand the app the follower's subtitle list so `s` cycles the party's
        # tracks instead of reporting "NONE IN FILE" off an empty session.
        self._emit_tracks()

    def _allow_tv(self):
        try:
            ip = self.cast.cast_info.host
        except Exception:
            return
        hub_allow_tv(ip)

    def load(self, req):
        self.last_load_req = dict(req)   # remember for the load-time wedge heal
        self.connect(req["device"])
        self.sess = None
        self._allow_tv()
        # WATCH PARTY FROM A CAST. The movie is already on the TV as a solo cast;
        # start-party re-issues the load with a party token so the SAME receiver
        # flips to a follower of the hub room (it keys SOLO off customData
        # .stateUrl), pulling the shared party lane and chasing the room clock —
        # exactly like a phone that opened the invite and cast it, but with no
        # phone in the loop.
        if req.get("partyToken"):
            self._party_follower_load(req, str(req["partyToken"]))
            return
        uri = req["uri"]
        vid = yt_id(uri)
        # YouTube ALWAYS streams through the hub lane (yt-dlp with the
        # desktop's Premium cookies -> ad-free googlevideo). The TV's native
        # YouTube receiver plays with the TV's own signed-out session and
        # injects ads — never launch it.
        if vid:
            # Away from home the hub's LAN base is dead; route the YouTube lane
            # over the Funnel's token-scoped surface instead (kind=yt — a video
            # id, never a path). Same home-vs-away switch the library cast uses.
            r = hub_reachable_or_wake()   # #224: wake a sleeping hub if on its LAN
            if r is None:
                return                     # asleep at home, wake failed (cast_error sent)
            roam_yt = (r is False)
            if roam_yt:
                fun, tok = hub_funnel(), browse_token()
                if not fun or not tok:
                    why = ("Funnel origin isn't configured (hubFunnel)"
                           if not fun else
                           "couldn't reach the hub to authorize the stream")
                    send({"event": "cast_error",
                          "error": f"can't cast YouTube away from home — {why}"})
                    return
                yt_base = f"{fun}/r/{tok}"
            else:
                yt_base = hub_base(self._peer())
            self.sess = {
                "ytvid": vid, "uri": uri, "base": yt_base, "roam_yt": roam_yt,
                "title": req.get("title") or "YouTube",
                "thumb": req.get("thumb") or "",
                # The app knows the duration from the listing — with it the
                # FIRST lane already shows a real timeline, not a LIVE bar.
                "duration": float(req.get("duration") or 0),
                "video": "", "safe": True,
                "audio": [], "subs": [], "aidx": 0, "sub": -1,
                "mode": "fit", "vtt": -1, "offset": 0.0, "lane": True,
                "owner": True,
                "subs_final": False,  # caption list still fetching (yt-dlp)
                "subsize": float(req.get("subsize") or 1.0),
                "lock": threading.Lock(),   # seek()'s lane-key snapshot mutex
            }
            threading.Thread(target=self._fetch_yt_captions,
                             args=(self.sess,), daemon=True).start()
            self._yt_lane(float(req.get("position") or 0))
            self._rescue_volume()
            return
        peer = self._peer()
        if uri.startswith("http://") or uri.startswith("https://"):
            r = hub_reachable_or_wake()   # #224: wake a sleeping hub if on its LAN
            if r is None:
                return                     # asleep at home, wake failed (cast_error sent)
            if r is False:
                # Away from home: the hub's LAN address reaches nothing here (and
                # the TV can't reach it either). Cast over the hub's Funnel.
                self._roam_load(uri, req)
                return
            # r is True -> hub is up (already, or we just woke it): cast direct-LAN.
        if uri.startswith("http://") or uri.startswith("https://"):
            # Hub-served library entry (satellite browsing the hub).
            direct, base, src = uri, hub_base(peer), uri
        elif codec_paths.hub_rel(uri):
            # The hub machine's own tree: codec-serve owns every lane. The
            # lane src is the URL form — the hub folds a URL's path onto
            # its root (the verified flow).
            base = f"http://{lan_ip(peer)}:{SERVE_PORT}"
            direct = base + quote(codec_paths.hub_rel(uri))
            src = direct
        else:
            # Machine-local media outside the hub tree (portable case).
            allow_path(uri)
            base = f"http://{lan_ip(peer)}:{SELF_PORT}"
            direct = f"{base}/file?path={quote(uri, safe='')}"
            src = uri
        # Receiver-truth 2026-07-18: progressive MKV over HTTP cannot seek on
        # the Bravia (every seek parks BUFFERING forever / restarts at 0) —
        # only container formats receivers index natively play direct.
        DIRECT_OK = (".mp4", ".m4v", ".mov", ".webm")
        # ...and only VIDEO codecs the receiver reliably direct-plays. A raw
        # 10-bit HEVC mp4 handed to <cast-media-player> stalls into a slideshow
        # (the media session freezes; #197) even though the TV's caps advertise
        # hevc10 — that path is for its NATIVE apps, not the cast surface. HEVC
        # belongs on the transcode/segment lane (how every 4K/HDR cast already
        # plays smoothly), so keep direct-play to h264/VP8/VP9 and let anything
        # else fall through to the lane.
        DIRECT_VIDEO = {"h264", "avc1", "vp8", "vp9"}
        info = probe(uri if os.path.exists(uri) else src)  # local read when we have it
        # Satellite (http src): the hub reads its own disk. Ask it when the remote
        # probe came up dry (slow WiFi / odd container → no duration) OR when no
        # embedded subs turned up — the hub knows about a .en.srt SIDECAR the
        # satellite CANNOT see locally (os.path.exists is False over http). Copy
        # back `extsub` too, not just duration: without it the external sub is
        # dropped and the cast reports "NONE IN FILE" even though the sidecar is
        # sitting right beside the file on the hub (e.g. RARBG mp4 + .en.srt).
        if src.startswith("http") and (not info.get("duration") or not info.get("subs")):
            try:
                import urllib.request
                d = json.loads(urllib.request.urlopen(
                    f"{base}/probe?src={quote(src, safe='')}",
                    timeout=25).read())
                if not info.get("duration") and d.get("duration"):
                    info["duration"] = d["duration"]
                if d.get("extsub"):
                    info["extsub"] = d["extsub"]
            except Exception:
                pass
        audio = info.get("audio") or []
        # Smart default track: the viewer's remembered language for THIS film if
        # any, else the film's shipped/original track. `needs_lane` below already
        # forces the encoded lane whenever this isn't track 0, so it plays.
        aidx0 = _choose_audio(audio, _library_rel(uri) or uri)
        subs = list(info.get("subs") or [])
        # External sidecar (`movie.en.srt` from /subfind) rides as pseudo
        # track -2 — the hub lane burns it like any selected sub.
        if os.path.exists(uri):
            sc_base = os.path.splitext(uri)[0]
            if any(os.path.isfile(sc_base + e)
                   for e in (".en.srt", ".srt", ".en.ass", ".ass")):
                # A sidecar .srt/.ass IS text — it converts to WebVTT like
                # any embedded track, so it can ride as a real Cast track the
                # TV renders itself instead of being burned into the picture.
                subs.append({"i": -2, "codec": "srt", "lang": "en",
                             "title": "external", "text": True})
        elif info.get("extsub"):
            subs.append({"i": -2, "codec": "srt", "lang": "en",
                         "title": "external", "text": True})
        # Forced-narrative subtitles (the foreign-dialogue lines a film shows on
        # purpose) auto-display by default, matched to the language being heard.
        alang = audio[aidx0].get("lang") if 0 <= aidx0 < len(audio) else None
        fsub = _forced_sub(subs, alang)
        self.sess = {
            "uri": uri, "direct_url": direct, "base": base, "src": src,
            "title": req.get("title") or Path(uri).stem,
            "thumb": req.get("thumb") or "",
            "duration": info.get("duration", 0),
            "video": info.get("video", ""),
            "safe": uri.lower().endswith(DIRECT_OK)
                    and (info.get("video") or "").lower() in DIRECT_VIDEO
                    and ((not audio) or audio[0]["codec"] in SAFE_AUDIO),
            "audio": audio, "subs": subs,
            "aidx": aidx0, "sub": fsub, "mode": "fit", "vtt": -1,
            "offset": 0.0, "lane": False, "owner": True,
            "subsize": float(req.get("subsize") or 1.0),
            "lock": threading.Lock(),   # seek()'s lane-key snapshot mutex
        }
        threading.Thread(target=self._warm_subs, args=(self.sess,),
                         daemon=True).start()
        self._start_stream(float(req.get("position") or 0))

    def attach(self, req):
        """Adopt whatever this device is ALREADY playing — another codec on
        the network may own the session. We become a full remote for it
        (pause/seek/tracks/stop) without interrupting a single frame."""
        try:
            self.connect(req["device"])
        except Exception as e:
            send({"event": "attached", "media": False, "error": str(e)})
            return
        mc = self.cast.media_controller
        try:
            mc.update_status()
        except Exception:
            pass
        st = None
        for _ in range(30):  # ~3s for the receiver status to land
            st = mc.status
            if st and st.player_state in ("PLAYING", "PAUSED", "BUFFERING") \
                    and st.content_id:
                break
            time.sleep(0.1)
        cid = (st.content_id or "") if st else ""
        state = st.player_state if st else ""
        if state not in ("PLAYING", "PAUSED", "BUFFERING") or not cid:
            send({"event": "attached", "media": False})
            return
        from urllib.parse import urlparse, parse_qs as _pq
        u = urlparse(cid)
        base = f"{u.scheme}://{u.netloc}"
        q = _pq(u.query)
        # Lane URLs carry the segment start — receiver time is relative to it.
        off = 0.0
        try:
            off = float(q.get("start", ["0"])[0])
        except Exception:
            pass
        pos = (st.adjusted_current_time or st.current_time or 0) + off
        dur = (st.duration or 0) + off
        title = getattr(st, "title", "") or "Now playing"
        # Adopt the lane's EXACT parameters from its URL (subsize/cc/burn):
        # 2026-07-19 crash class — an attached worker rebuilding with its own
        # defaults hashed to a DIFFERENT hub session and evicted the owner's
        # live encoder mid-play, and the two workers then fought.
        try:
            subsize = float(q.get("subsize", ["1"])[0])
        except ValueError:
            subsize = 1.0
        common = {"title": title, "thumb": "", "duration": dur,
                  "aidx": 0, "sub": -1, "mode": "fit", "vtt": -1,
                  "offset": off, "subsize": subsize, "base": base,
                  "media_id": cid, "owner": False,
                  "lock": threading.Lock()}   # seek()'s lane-key snapshot mutex
        if "/hls/" in u.path and q.get("kind", ["file"])[0] == "yt":
            vid = q.get("v", [""])[0]
            self.sess = {**common, "ytvid": vid,
                         "uri": f"https://www.youtube.com/watch?v={vid}",
                         "video": "", "safe": True, "audio": [], "subs": [],
                         "lane": True, "hls": True, "subs_final": False,
                         "want_cc": q.get("cc", [""])[0],
                         "duration": float(q.get("dur", ["0"])[0]) or dur}
            threading.Thread(target=self._fetch_yt_captions,
                             args=(self.sess,), daemon=True).start()
        elif "/hls/" in u.path:
            src = q.get("src", [""])[0]
            self.sess = {**common, "uri": src, "src": src,
                         "direct_url": src, "video": q.get("v", [""])[0],
                         "aidx": int(q.get("aidx", ["0"])[0] or 0),
                         "mode": q.get("mode", ["fit"])[0],
                         "safe": False, "audio": [], "subs": [],
                         "lane": True, "hls": True,
                         # Dash lane survives re-attach: the lane URL carries
                         # &fmt=dash (the SDR ladder's pl.m3u8 does not), so a seek
                         # keeps skipping the junk prewarm after a re-attach too.
                         "dash_cast": q.get("fmt", [""])[0] == "dash",
                         # DV lane survives re-attach: the receiver's re-warm URL
                         # still carries &dv=1, so seeks keep the non-blocking path.
                         "dv_lane": q.get("dv", ["0"])[0] == "1",
                         "want_burn": int(q.get("burn", ["-1"])[0] or -1),
                         "duration": float(q.get("dur", ["0"])[0]) or dur}
            threading.Thread(target=self._fill_attached,
                             args=(self.sess, src), daemon=True).start()
        elif "/ytstream" in u.path:
            vid = q.get("v", [""])[0]
            self.sess = {**common, "ytvid": vid,
                         "uri": f"https://www.youtube.com/watch?v={vid}",
                         "video": "", "safe": True, "audio": [], "subs": [],
                         "lane": True, "subs_final": False}
            threading.Thread(target=self._fetch_yt_captions,
                             args=(self.sess,), daemon=True).start()
        elif "/transcode" in u.path:
            src = q.get("src", [""])[0]
            self.sess = {**common, "uri": src, "src": src,
                         "direct_url": src, "video": q.get("v", [""])[0],
                         "aidx": int(q.get("aidx", ["0"])[0] or 0),
                         "safe": False, "audio": [], "subs": [],
                         "mode": q.get("mode", ["fit"])[0], "lane": True}
            threading.Thread(target=self._fill_attached,
                             args=(self.sess, src), daemon=True).start()
        else:
            self.sess = {**common, "uri": cid, "src": cid, "direct_url": cid,
                         "video": "", "safe": True, "audio": [], "subs": [],
                         "lane": False}
            threading.Thread(target=self._fill_attached,
                             args=(self.sess, cid), daemon=True).start()
        self.last_pos = pos
        self._mark_lane_start()
        self.had_played = True
        # Warm the per-film crop measurement in the background so the FIRST zoom
        # toggle is instant (film_crop runs a cropdetect pre-pass, then caches).
        # Against uri (the LOCAL path) — src is the hub URL ffmpeg-probe can't stat.
        _wuri = self.sess.get("uri") or ""
        if _wuri and not self.sess.get("ytvid") and os.path.exists(_wuri):
            threading.Thread(target=lambda: hublib.film_crop(_wuri),
                             daemon=True).start()
        send({"event": "attached", "media": True, "title": title,
              "uri": self.sess["uri"], "position": pos, "duration": dur,
              "state": state})
        self._emit_tracks()

    def _fill_attached(self, sess, probe_src):
        """Background: probe the adopted stream's source for track lists +
        duration so the full remote (audio/subs/mode) works on it too."""
        info = probe(probe_src)
        if self.sess is not sess:
            return
        sess["audio"] = info.get("audio") or []
        sess["subs"] = info.get("subs") or []
        # Attached file lane: mirror the burned sub track from the lane URL.
        want = sess.pop("want_burn", -1)
        if want >= 0 and sess["sub"] < 0:
            for i, t in enumerate(sess["subs"]):
                if t.get("i") == want:
                    sess["sub"] = i
                    break
        sess["video"] = sess["video"] or info.get("video", "")
        if not sess["duration"]:
            sess["duration"] = info.get("duration", 0)
        if sess["audio"]:
            sess["safe"] = sess["src"].lower().split("?")[0].endswith(
                (".mp4", ".m4v", ".mov", ".webm")) \
                and sess["audio"][0]["codec"] in SAFE_AUDIO
        self._emit_tracks()
        threading.Thread(target=self._warm_subs, args=(sess,),
                         daemon=True).start()

    def _clamp_pos(self, position):
        """Clamp a requested position to [0, duration-2]. A seek AT/PAST the end
        drives the receiver IDLE (the party cast-wedge trigger) — keep a hair off
        EOF. Only bites when duration is known; a dur-unknown session (the real
        wedge precondition) is fixed upstream by the app sending a resolvable key."""
        position = max(0.0, position)
        s = self.sess
        dur = (s.get("duration") if s else 0) or 0
        # Keep ~20s off EOF: a seek into the final segment can't build a forward
        # buffer on the receiver and times out -> IDLE (found live seeking to the
        # end of a 4K HDR cast). Give it several segments of runway.
        if dur > 0 and position > dur - 20.0:
            position = max(0.0, dur - 20.0)
            dbg(f"clamp seek -> {position:.1f} (dur {dur:.1f})")
        return position

    def seek(self, position):
        if not self.cast:
            return
        position = self._clamp_pos(position)
        s = self.sess
        if s and s.get("hls"):
            # HLS: the receiver owns the whole timeline — plain absolute
            # seek. PREWARM the hub encoder at the target NOW: 4K segments
            # take seconds to build cold and the Sony gives up waiting and
            # snaps back (the author's "buffers then resumes from original spot").
            self.last_pos = position
            self.last_seek_at = time.time()
            if s.get("dv_lane"):
                # DV copy lane: DON'T block, and DON'T prewarm.
                #  • The receiver swallows a far/head seek and re-warms the lane
                #    itself (SEEK interceptor → rewarmTo), so media_controller.seek
                #    gets NO response and blocks the whole 10 s default — freezing
                #    the single command loop (reactive recovery can't run) and
                #    spamming takeover→re-attach. Deliver it fire-and-forget on a
                #    daemon thread with a short timeout: the SEEK message still
                #    reaches the receiver (arming its re-warm), but a swallowed-seek
                #    timeout dies OFF the main loop.
                #  • _hls_prewarm targets the wrong grid/key for DV (position//4,
                #    no &fmt=dash&dv=1) so it never moves the DV warm anyway (the
                #    receiver's re-warm does) — at worst it spawns a competing
                #    encoder. Skip it.
                def _dv_seek(mc=self.cast.media_controller, p=position):
                    try:
                        mc.seek(p, timeout=3.0)
                    except Exception:
                        pass
                threading.Thread(target=_dv_seek, daemon=True).start()
                return
            # HDR10 / heavy-4K-SDR per-segment dash lane: the hub produces the
            # target segment on demand and dvWarm=0 so the receiver doesn't swallow
            # the seek — the native seek acks and lands. SKIP _hls_prewarm: its URL
            # (pos//4, no &fmt=dash) hits a different session key and reaps THIS
            # lane's encoder via hls_stop_others on every seek (mirror the DV fix).
            # Only the true SDR HLS ladder keeps prewarm — its key matches, so the
            # warm actually pre-races the ladder's target encoder.
            if not s.get("dash_cast"):
                # #21: freeze the lane-key fields UNDER LOCK before handing them to
                # the daemon thread. Reading the live s on that thread let a
                # concurrent set_audio/set_sub change aidx/sub mid-build, producing a
                # mismatched session key whose warm reaped the LIVE encoder.
                # Satellite fix: some session builders never set "lock" (it was only
                # ever added on the hub's own paths) — a fresh Lock() fallback keeps
                # the snapshot correct instead of raising KeyError('lock') and killing
                # the seek (the author's 7x `error: 'lock'`).
                with (s.get("lock") or threading.Lock()):
                    ks = {k: s.get(k) for k in
                          ("base", "ytvid", "sub", "subs", "aidx",
                           "src", "video", "duration", "subsize", "lane_url")}
                threading.Thread(target=self._hls_prewarm,
                                 args=(ks, position), daemon=True).start()
            # Fire-and-forget, exactly like the DV lane above. A satellite HDR10
            # dash seek that the receiver swallows blocks this call for the WHOLE
            # 10s default and freezes the single command loop (measured: seek timed
            # out 10s, worker frozen, later presses queued). Off-loop with a short
            # timeout: the SEEK still reaches the receiver, a swallow can't freeze us.
            def _seek_ff(mc=self.cast.media_controller, p=position):
                try:
                    mc.seek(p, timeout=3.0)
                except Exception:
                    pass
            threading.Thread(target=_seek_ff, daemon=True).start()
            return
        if s and s["lane"]:
            delta = position - self.last_pos
            rel = position - s["offset"]
            if -12 <= delta <= 75 and rel >= 0:
                # Near seek: the fMP4 buffer covers it — receiver-native
                # lands instantly, watchdog hard-restarts if it missed.
                self.pending_seek = (position, time.time())
                self.cast.media_controller.seek(rel)
                # Poke a status update right after the verdict window so the
                # watchdog gets a callback even if the receiver goes quiet.
                def poke():
                    try:
                        self.cast.media_controller.update_status()
                    except Exception:
                        pass
                threading.Timer(3.3, poke).start()
            else:
                # Big jump: certainly outside the buffer — skip the doomed
                # native attempt + 4s verdict and restart the lane at the
                # target NOW (absolute timestamps make this exact).
                self._hard_seek(position)
        else:
            self.cast.media_controller.seek(position)

    def _hard_seek(self, position):
        s = self.sess
        if not s:
            return
        position = self._clamp_pos(position)
        if s.get("ytvid"):
            self._yt_lane(position)
        else:
            self._start_stream(position)

    def _cap_url(self, track):
        """The VTT url the receiver hand-renders for a text sub track."""
        s = self.sess
        if not s or not track:
            return None
        if s.get("roam"):
            # Away from home the Funnel surface is keyed by manifest INDEX,
            # never a path: /subs?src=<path>&i= was read there as an index into
            # the manifest and answered another title's track list (no cues).
            return f"{s['rbase']}/sub?i={s['ridx']}&t={track['i']}"
        return (f"{s['base']}/subs?src={quote(s['src'], safe='')}"
                f"&i={track['i']}")

    def _roam_caf_sub_off(self):
        """A roaming load sideloads the chosen sub as a CAF text track; once the
        overlay takes over (another track, or off) that one must go, or it
        stays on screen under the new choice."""
        if self.sess and self.sess.get("roam") and self.cast:
            try:
                self.cast.media_controller.disable_subtitle()
            except Exception:
                pass

    def _push_sub(self, url):
        """Push the active sub's VTT url (or None=off) to the receiver's hand-
        render overlay — instant, no lane restart."""
        sc = getattr(self.cast, "_codec_sub", None) if self.cast else None
        if sc:
            sc.set_sub(url)

    def push_style(self):
        """The cast caption style, live: Settings changed while a cast is on."""
        sc = getattr(self.cast, "_codec_sub", None) if self.cast else None
        if sc:
            sc.set_style(cap_style())

    def _sidecar_present(self):
        """Is there a sidecar for the cast film NOW (one fetched while
        casting)? Beside a local file by its name; else the hub's word — the
        LAN /probe's extsub, the token surface's track list when roaming."""
        s = self.sess
        if not s:
            return False
        uri = s.get("uri") or ""
        if os.path.exists(uri):
            b = os.path.splitext(uri)[0]
            return any(os.path.isfile(b + e)
                       for e in (".en.srt", ".srt", ".en.ass", ".ass"))
        import urllib.request
        try:
            if s.get("roam"):
                d = json.loads(urllib.request.urlopen(
                    f"{s['rbase']}/subs?i={s['ridx']}", timeout=15).read())
                return any(t.get("i") == -2 for t in d.get("subs") or [])
            d = json.loads(urllib.request.urlopen(
                f"{s['base']}/probe?src={quote(s['src'], safe='')}",
                timeout=25).read())
            return bool(d.get("extsub"))
        except Exception:
            return False

    def add_sub(self, refresh=False):
        """A subtitle fetched WHILE casting (the hub saved a sidecar beside the
        film): learn it as track -2 without reloading the lane, show it, say
        so on the TV. `refresh` re-pushes the track the hub has since RE-TIMED,
        with a cache-buster so the receiver fetches the new cues. False when
        there is nothing to learn (no sidecar yet, a YouTube or party cast)."""
        s = self.sess
        if not s or s.get("ytvid") or (s.get("party") and not s.get("lane")):
            return False
        subs = list(s.get("subs") or [])
        idx = next((n for n, t in enumerate(subs) if t.get("i") == -2), -1)
        if idx < 0:
            if not self._sidecar_present():
                return False
            subs.append({"i": -2, "codec": "srt", "lang": "en",
                         "title": "external", "text": True})
            s["subs"] = subs
            idx = len(subs) - 1
        s["sub"] = idx
        s["vtt"] = -2
        self._roam_caf_sub_off()
        url = self._cap_url(subs[idx])
        if refresh and url:
            url += f"&v={int(time.time())}"
        self._push_sub(url)
        self._emit_tracks()
        self._push_toast("SUBTITLES RE-TIMED" if refresh else "SUBTITLES · ENG")
        return True

    def _push_toast(self, text):
        """Flash a short action toast on the receiver (sub/audio/mode change)."""
        tc = getattr(self.cast, "_codec_toast", None) if self.cast else None
        if tc and text:
            tc.show(text)

    def _audio_toast(self, idx=None):
        """'AUDIO · ENG 5.1' for a track — the REQUESTED index when given, so the
        toast can flash BEFORE the lane re-warm (on the live picture), else the
        current one."""
        s = self.sess or {}
        a = s.get("audio") or []
        i = s.get("aidx", 0) if idx is None else idx
        if 0 <= i < len(a):
            lang = (a[i].get("lang") or "").upper()
            ch = {1: "MONO", 2: "STEREO", 6: "5.1", 8: "7.1"}.get(a[i].get("channels"))
            tail = (lang + (" " + ch if ch else "")) if lang else (ch or "TRACK %d" % (i + 1))
            return "AUDIO · " + tail
        return "AUDIO"

    def _sub_toast(self):
        """'SUBTITLES · ENG' for the active track, or 'SUBTITLES OFF'."""
        s = self.sess or {}
        i = s.get("sub", -1)
        subs = s.get("subs") or []
        if not (isinstance(i, int) and 0 <= i < len(subs)):
            return "SUBTITLES OFF"
        lang = (subs[i].get("lang") or "").upper()
        return "SUBTITLES · " + (lang or "ON")

    def set_sub(self, index):
        s = self.sess
        if not s:
            return
        if s.get("party") and not s.get("lane"):
            # Follower: no lane, tracks are sideloaded on the receiver.
            return self._party_set_sub(index)
        if s.get("ytvid"):
            # YouTube lives on the lane full-time (ad-free); a caption change
            # restarts it at the current position with/without the burn.
            s["sub"] = index if (index is not None and 0 <= index < len(s["subs"])) else -1
            if s["lane"] or s["sub"] >= 0:
                self._yt_lane(self.last_pos)
            else:
                self._emit_tracks()
            return
        if index is None or index < 0 or index >= len(s["subs"]):
            # s["vtt"]>=0 means the current sub is HAND-RENDERED (sideloaded) —
            # clearing the overlay is instant. Only a BURNED sub (piped lane,
            # vtt<0 with a sub on) needs a re-encode to take it back off.
            # vtt>=0 (embedded) AND vtt==-2 (sidecar) are both HAND-RENDERED
            # overlays — clearing them is instant. Only vtt==-1 with a sub on is
            # a sub BURNED into the lane (SDR-burn), which needs a re-encode to
            # take back off. (The sidecar's track i is -2, so a plain "vtt<0"
            # test wrongly re-warmed the cast when toggling a downloaded sub off.)
            was_burned = s.get("sub", -1) >= 0 and s.get("vtt", -1) == -1 \
                and not s.get("roam")          # roaming sideloads, never burns
            s["sub"] = -1
            s["vtt"] = -1
            self._roam_caf_sub_off()
            if was_burned:
                self._start_stream(self.last_pos)
            else:
                self._push_sub(None)             # clear the overlay, instant
                self._emit_tracks()
            return
        track = s["subs"][index]
        if not self._sub_ready(track):
            send({"event": "cast_error",
                  "error": "preparing subtitles (large file) — try again in a minute"})
            self._emit_tracks()
            return
        s["sub"] = index
        # Text subs AND OCR'd bitmap subs both hand-render (the hub serves a VTT
        # for either via /subs) — instant, no lane restart, DV preserved.
        s["vtt"] = track["i"]
        self._roam_caf_sub_off()
        self._push_sub(self._cap_url(track))
        self._emit_tracks()

    def _remember_audio(self, index):
        """Persist the viewer's audio-language choice for this film, so the next
        cast of it defaults to the same language (per-film memory)."""
        s = self.sess
        if not s or s.get("ytvid"):
            return
        audio = s.get("audio") or []
        if 0 <= index < len(audio):
            key = _library_rel(s.get("uri") or "") or (s.get("uri") or "")
            _remember_audio_lang(key, audio[index].get("lang"))

    def set_audio(self, index):
        s = self.sess
        if not s or s.get("ytvid"):
            return
        if index is None or index < 0 or index >= len(s["audio"]):
            return
        s["aidx"] = index
        self._remember_audio(index)
        self._start_stream(self.last_pos)

    def _zoom_scale(self, s):
        """The receiver scale for this session's mode — 1.0 (no zoom) unless the
        mode is zoom AND the film has bars to remove. film_crop is cached, so this
        is cheap after the load-time warm.

        Measures against s["uri"] (the LOCAL file path), NOT s["src"] — src is the
        hub URL the receiver fetches, which os.stat can't read (that silently keyed
        the cache as `<url>|0|0` -> {} and made every zoom a no-op)."""
        if not s or s.get("mode") != "zoom":
            return 1.0
        uri = s.get("uri") or ""
        c = None
        got = False
        # Satellite (uri is a hub URL, not a local file): ask the HUB to measure
        # the crop on its own disk (/crop endpoint). film_crop HERE would decode a
        # 4K remux over HTTP -- the ~27s stall this whole change removed. The hub
        # caches the result (shared with desktop zoom usage) so it's usually
        # instant; a hub answer, even {} (no crop), is authoritative.
        if uri and not os.path.exists(uri):
            base = s.get("base") or ""
            src = s.get("src") or uri
            if base:
                try:
                    import urllib.request
                    c = json.loads(urllib.request.urlopen(
                        f"{base}/crop?src={quote(src, safe='')}",
                        timeout=25).read())
                    got = True
                except Exception:
                    got = False
        # Hub (local file), or the hub call failed: measure locally.
        if not got:
            try:
                c = hublib.film_crop(uri)
            except Exception:
                c = None
        return float(c["scale"]) if c and c.get("scale") else 1.0

    def _zoom_timeline(self, s):
        """The warmed crop TIMELINE for this source, or None.

        Films that change aspect partway (IMAX sequences) cannot be served by one
        scale: the one that fills the scope sections pushes ~21% of every IMAX shot
        off the screen. codec_cropwarm measures where they change, ahead of time;
        this only READS that — nothing here ever decodes, so it cannot block the
        way an unwarmed film_crop could.

        Same local-vs-satellite split as _zoom_scale: the hub reads its own cache,
        a satellite asks the hub over /croptl."""
        uri = s.get("uri") or ""
        if uri and not os.path.exists(uri):
            base, src = s.get("base") or "", s.get("src") or uri
            if not base:
                return None
            try:
                import urllib.request
                tl = json.loads(urllib.request.urlopen(
                    f"{base}/croptl?src={quote(src, safe='')}", timeout=15).read())
                return tl or None
            except Exception:
                return None
        try:
            return hublib.crop_timeline(uri) or None
        except Exception:
            return None

    def _push_zoom(self):
        """Send the current mode's scale to the receiver — display-side, so it
        re-scales the live picture with no reload. Also stashed in s["zoom_scale"]
        so it rides customData on the next (re)load and survives a seek-rewarm.

        OFF THE MAIN LOOP. _zoom_scale -> hublib.film_crop runs an ffmpeg
        cropdetect pre-pass; on a SATELLITE the source is a hub URL, not a local
        file, so that pass decodes 5 sample points of a 4K remux over HTTP and
        BLOCKS the single command loop for tens of seconds to minutes (measured:
        a 27s freeze on Blade; ~4min on a big remux — froze zoom AND every queued
        CH/seek press behind it). Compute on a daemon thread and push the scale
        when it lands; a re-press is instant once film_crop has cached the key."""
        s = self.sess
        if not s or not self.cast:
            return
        cast = self.cast
        def work(sess=s, cast=cast):
            # TIMELINE FIRST, and skip film_crop entirely when there is one.
            # The receiver uses the per-segment scales when a timeline is present
            # and ignores the single scale completely (setZoom: `if(zoomTl)...
            # else applyZoom(scale)`), so measuring it is work whose answer is
            # thrown away — and that measurement is the slow part: a cropdetect
            # pre-pass over five points of a 4K remux, 27s on Blade and ~4min on
            # a big one. Variable-aspect films are exactly the ones with a
            # timeline, so they were paying the whole cost for nothing.
            tl = (self._zoom_timeline(sess) or {}).get("segments") \
                if sess.get("mode") == "zoom" else None
            if self.sess is not sess:          # user moved on while we measured
                return
            if tl:
                scale = 1.0                    # unused by the receiver; see above
            else:
                scale = self._zoom_scale(sess)
                if self.sess is not sess:
                    return
            sess["zoom_scale"] = scale
            sess["zoom_tl"] = tl
            zc = getattr(cast, "_codec_zoom", None)
            if zc and self.cast is cast:
                zc.set_zoom(scale, sess.get("zoom_tl"))
        threading.Thread(target=work, daemon=True).start()

    def screen_mode(self, mode):
        s = self.sess
        if not s or s.get("ytvid") or mode not in ("fit", "zoom"):
            return
        s["mode"] = mode
        self._push_zoom()      # display-side transform on the TV — no re-encode
        self._emit_tracks()    # reflect the new mode in the app

    def apply_swap_state(self, req):
        """Absorb a swap op into session state without touching the stream —
        used when coalescing a burst of remote presses into one restart."""
        s = self.sess
        if not s:
            return
        op = req.get("op")
        if op == "set_sub":
            i = int(req.get("index", -1))
            s["sub"] = i if 0 <= i < len(s["subs"]) else -1
        elif op == "set_audio":
            i = int(req.get("index", 0))
            if 0 <= i < len(s["audio"]) and not s.get("ytvid"):
                s["aidx"] = i
                self._remember_audio(i)
        elif op == "screen_mode":
            m = req.get("mode", "fit")
            if m in ("fit", "zoom") and not s.get("ytvid"):
                s["mode"] = m
        elif op == "seek":
            self.last_pos = max(0.0, float(req.get("position", 0)))

    def handle_burst(self, reqs):
        """A rapid run of track/audio/mode/seek presses collapses into ONE
        stream restart. Restarting per keypress stacked hub encoders and
        wedged the cast (the 2026-07-16 live-test failure)."""
        # The sub BEFORE the burst: set_sub decides "was it burned in?" from
        # s["sub"], which apply_swap_state has already overwritten — so turning
        # a burned sub off inside a burst never re-encoded and it stayed on.
        pre_sub = self.sess.get("sub", -1) if self.sess else -1
        for r in reqs:
            self.apply_swap_state(r)
        s = self.sess
        if not s or not self.cast:
            return {"ok": True}
        if s.get("party") and not s.get("lane"):
            # Follower: the only meaningful swap is the sideloaded subtitle
            # track (audio/mode belong to the party's one shared lane, not to
            # this receiver). apply_swap_state already folded the final s["sub"]
            # in; push it as an EDIT_TRACKS_INFO, no lane to restart.
            if any(r.get("op") == "set_sub" for r in reqs):
                self._party_set_sub(s["sub"])
            else:
                self._emit_tracks()
            return {"ok": True}
        if 0 <= s["sub"] < len(s["subs"]) and \
                not self._sub_ready(s["subs"][s["sub"]]):
            s["sub"] = -1
            send({"event": "cast_error",
                  "error": "preparing subtitles (large file) — try again in a minute"})
        # screen_mode is NOT a lane restart any more — zoom is a receiver-side
        # transform, so a mode press just re-pushes the scale (no re-encode, no
        # rebuffer). It's dropped from tracks_changed and handled on its own.
        tracks_changed = any(r.get("op") in ("set_sub", "set_audio")
                             for r in reqs)
        audio_changed = any(r.get("op") == "set_audio" for r in reqs)
        sub_changed = any(r.get("op") == "set_sub" for r in reqs)
        mode_changed = any(r.get("op") == "screen_mode" for r in reqs)
        seeked = any(r.get("op") == "seek" for r in reqs)
        if mode_changed:
            self._push_zoom()
        if s.get("ytvid"):
            if tracks_changed and (s["lane"] or s["sub"] >= 0):
                self._yt_lane(self.last_pos)
            elif seeked:
                self.seek(self.last_pos)
            elif not mode_changed:
                self._emit_tracks()
        elif audio_changed and (s["lane"] or s["aidx"] != 0 or not s["safe"]):
            # Audio-track switch rebuilds the per-aidx lane (the final sub + zoom
            # ride forward via customData). Phase-2 TODO: in-band audio switch.
            self._push_toast(self._audio_toast())  # before the re-warm (live picture)
            self._start_stream(self.last_pos)
        elif sub_changed:
            # Sub-only burst: hand-render the final sub with NO lane restart (DV
            # preserved), exactly like a single set_sub press — which also covers
            # the one case that still needs a re-encode (removing a BURNED sub).
            final = s["sub"]
            restarts = final < 0 and pre_sub >= 0 and s.get("vtt", -1) == -1
            s["sub"] = pre_sub                # let set_sub see what was on
            self.set_sub(final)
            # A seek in the same burst: set_sub never seeks, so it was dropped
            # (the TV stayed put while last_pos claimed the target). A burned-
            # sub removal restarts the lane AT last_pos, which already covers it.
            if seeked and not restarts:
                self.seek(self.last_pos)
        elif seeked:
            self.seek(self.last_pos)  # native-first (in-buffer = instant)
            self._emit_tracks()
            # RE-PUSH THE ZOOM. A DV far-seek re-warms the lane, and the new
            # media element comes up without the CSS transform — the zoom was
            # silently lost on every seek, which reads as "it worked, then it
            # went letterboxed again". zoomTick alone cannot recover it: it only
            # applies on a segment CHANGE, so landing back inside the same
            # segment leaves the picture unzoomed indefinitely.
            # Affordable now only because _push_zoom reads the timeline first
            # and no longer runs a cropdetect pre-pass on a film that has one.
            if s.get("mode") == "zoom":
                self._push_zoom()
        else:
            self._emit_tracks()
        # Confirm sub/mode on the TV (audio already toasted before its re-warm,
        # so it lands on the live picture rather than the LOADING card).
        if sub_changed:
            self._push_toast(self._sub_toast())
        if mode_changed:
            self._push_toast("ZOOM" if s.get("mode") == "zoom" else "FIT")
        return {"ok": True}

    def handle(self, req):
        op = req.get("op", "")
        dbg(f"op {json.dumps(req)[:260]}")
        if op == "load":
            try:
                self.load(req)
            except Exception as e:
                # load() assigns self.sess BEFORE _start_stream/cast_load, so a
                # failure there (device refused, Funnel unreachable, quick_play
                # timeout) would otherwise leave a phantom owner+lane session
                # whose stream never started — a later IDLE(ERROR) callback then
                # fires _recover against it. Roll it back and report the failure.
                self.sess = None
                dbg(f"load failed: {e}")
                send({"event": "cast_error",
                      "error": f"couldn't start the cast — {e}"})
        elif op == "pause":
            self.cast and self.cast.media_controller.pause()
        elif op == "resume":
            self.cast and self.cast.media_controller.play()
        elif op == "seek":
            self.seek(float(req.get("position", 0)))
        elif op == "volume":
            if self.cast:
                if req.get("dir") == "up":
                    self.cast.volume_up(0.05)
                else:
                    self.cast.volume_down(0.05)
        elif op == "rate":
            self.cast and self.cast.media_controller.set_playback_rate(
                float(req.get("value", 1.0)))
        elif op == "set_sub":
            self.set_sub(int(req.get("index", -1)))
            self._push_toast(self._sub_toast())
        elif op == "add_sub":
            if not self.add_sub(refresh=bool(req.get("refresh"))):
                send({"event": "cast_error",
                      "error": "no subtitle file to show yet"})
        elif op == "sub_style":
            self.push_style()
        elif op == "set_audio":
            # Flash the toast BEFORE the lane re-warm so it lands on the live
            # picture (and feels instant), not the black LOADING card 8s later.
            self._push_toast(self._audio_toast(int(req.get("index", 0))))
            self.set_audio(int(req.get("index", 0)))
        elif op == "screen_mode":
            self.screen_mode(req.get("mode", "fit"))
            self._push_toast("ZOOM" if (self.sess or {}).get("mode") == "zoom" else "FIT")
        elif op == "toast":
            # App-driven TV message (UP NEXT at the end credits): held for `ms`,
            # or taken down with hide.
            tc = getattr(self.cast, "_codec_toast", None) if self.cast else None
            if tc:
                tc.show(req.get("text", ""), req.get("ms"), bool(req.get("hide")),
                        bool(req.get("prompt")))
        elif op == "_hard_seek":
            # Watchdog recovery: restart the lane at the reported position.
            self.cast and self.sess and self._hard_seek(
                max(0.0, float(req.get("position", 0))))
        elif op == "_roam_stepdown":
            # The roaming DV / HDR10 lane starved (_roam_starved): the adaptive
            # ladder from here on, at the spot the picture reached. Say so on
            # the TV and in the app — a quieter picture is a choice, not a fault.
            if not (self.sess and self.sess.get("roam") and self.cast):
                return {"ok": True}
            if self.sess.get("force_ladder"):
                return {"ok": True}      # a second verdict queued behind the first
            self.sess["force_ladder"] = True
            # a wedge heal re-issues the last load: it must come back on the ladder
            if self.last_load_req:
                self.last_load_req["force_ladder"] = True
            lane = "DOLBY VISION" if self.sess.get("dv_lane") else "HDR"
            self._push_toast(f"LINK TOO THIN FOR {lane} · SWITCHING TO THE ADAPTIVE STREAM")
            send({"event": "cast_error",
                  "error": "link too thin for the full-quality lane — switching to the "
                           "adaptive stream for the rest of this cast"})
            dbg(f"roam step-down ({req.get('why', '')}) at {req.get('position', 0)}")
            self._start_roam_stream(max(0.0, float(req.get("position", 0))))
            return {"ok": True}
        elif op == "_wedge_reload":
            # Load-time wedge heal (armed by _lane_watchdog): the receiver
            # half-armed during the load. Quit the receiver app for a clean
            # slate, then re-issue the SAME load — mirrors the manual
            # force-stop-mediashell + re-cast. Bounded quit like the stop op.
            # Drop any cached home/away verdict first: a wedge reload often follows
            # a wake/resume, and a stale 'away' would send this reload's cast over
            # the Funnel while actually at home.
            # Only for a load THIS worker made and that is still the session:
            # after a stop (queued behind this op) or an adopted/attached
            # session, last_load_req is another title — or None, and quitting
            # then just left the TV on its home screen.
            if not (self.sess and self.last_load_req):
                dbg("wedge reload skipped — no live session of our own to reload")
                return {"ok": True}
            _ROAM["lan"] = None
            try:
                if self.cast:
                    self.cast.quit_app(timeout=3)
            except Exception:
                pass
            time.sleep(1.5)   # let the receiver tear down before the fresh load
            if self.last_load_req:
                lr = dict(self.last_load_req)
                # A mid-film wedge escalation carries the CURRENT position — reload
                # there, not at the original resume point (last_load_req is the first
                # load; the receiver's own re-warms since then never touched it).
                p = req.get("position")
                if p is not None:
                    lr["position"] = p
                lr["_keep_clock"] = True   # roaming: the no-picture clock keeps counting
                self.load(lr)
        elif op == "attach":
            self.last_load_req = None    # an adopted session isn't a load of ours
            self.attach(req)
        elif op == "stop":
            self.sess = None
            self.last_load_req = None
            if self.cast:
                # Leave the TV fully CLEAN on stop: quit the whole receiver app
                # (the TV returns to its home screen) rather than only stopping
                # the media, which left a lingering receiver that accumulated
                # into a wedged session across cast/stop cycles — it ACKs new
                # loads but won't play (the recurring "stuck on idle"). Bounded
                # at 3s so it can't hang the worker the way media stop did (10s).
                try:
                    self.cast.quit_app(timeout=3)
                except Exception:
                    pass
        elif op == "disconnect":
            self.disconnect()
        elif op == "rescan":
            self.rescan()
        elif op == "add_ip":
            self.add_ip(str(req.get("ip", "")).strip())
        elif op == "ping":
            pass
        else:
            raise RuntimeError(f"unknown op {op!r}")
        return {"ok": True}


SWAP_OPS = {"set_sub", "set_audio", "screen_mode", "seek"}


def main():
    w = Worker()
    send({"event": "ready"})
    # stdin feeds a queue so swap bursts can be coalesced: a stream restart
    # takes seconds, so five quick presses must become one restart, not five.
    inq = queue.Queue()
    w.inbox = inq  # lane watchdog queues recovery ops here

    def reader():
        for line in sys.stdin:
            inq.put(line)
        inq.put(None)

    threading.Thread(target=reader, daemon=True).start()

    def parse(line):
        line = (line or "").strip()
        if not line:
            return None
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            return None

    pending = []  # parsed reqs waiting behind a burst
    while True:
        if pending:
            req = pending.pop(0)
        else:
            line = inq.get()
            if line is None:
                return
            req = parse(line)
            if req is None:
                continue

        burst = []
        # A lone screen_mode is a display-side transform (no lane restart), so it
        # must NOT sit in the 0.4s coalescing window — that 400ms beat made a
        # single zoom/fit press feel dead and users re-pressed it (#236). It stays
        # in SWAP_OPS below, so it still coalesces harmlessly if it lands mid-burst.
        if req.get("op") in SWAP_OPS and req.get("op") != "screen_mode" and not pending:
            burst = [req]
            while True:
                try:
                    line = inq.get(timeout=0.4)
                except queue.Empty:
                    break
                if line is None:
                    break
                nxt = parse(line)
                if nxt is None:
                    continue
                if nxt.get("op") in SWAP_OPS:
                    burst.append(nxt)
                else:
                    pending.append(nxt)
                    break

        try:
            if len(burst) > 1:
                reply = w.handle_burst(burst)
            else:
                reply = w.handle(req)
        except Exception as e:
            reply = {"ok": False, "error": str(e).replace("\n", " ")[:300]}
        if len(burst) > 1:
            for r in burst:
                if not r.get("internal"):
                    send({**reply, "id": r.get("id")})
        elif not req.get("internal"):
            reply["id"] = req.get("id")
            send(reply)


if __name__ == "__main__":
    main()
