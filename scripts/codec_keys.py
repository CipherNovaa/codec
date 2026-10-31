#!/usr/bin/env python3
"""The keys codec's art and details come through — carried by codec itself.

Kodi's scrapers ship their own TMDB and fanart.tv keys, so nobody installing
Kodi ever signs up for one; codec does the same. A person CAN bring their own
(Settings ▸ LIBRARY ▸ METADATA), as Kodi lets you add a fanart.tv personal key:

  settings.tmdbApiKey        your own TMDB key, used instead of codec's
  settings.fanartArt         false = no fanart.tv artwork at all (default on)
  settings.fanartApiKey      a fanart.tv PROJECT key instead of codec's
  settings.fanartPersonalKey your fanart.tv personal key — new artwork reaches
                             you in ~48 h instead of 7 days (sent as client_key)

TMDB rate-limits by address, not by key, so one shared key serves everyone.

codec's own keys are the two constants below. They're the app's, not a
person's: whoever ships codec decides what goes here (Kodi and Jellyfin
publish theirs in their source; for a public codec, give it its own TMDB
account key and ask fanart.tv for a project key — fanart.tv/get-an-api-key).
`codec_keys.py --adopt-mine` copies this machine's own config keys into them.
"""
import json
import os
import re
import sys

CFG = os.path.expanduser("~/.config/codec/config.json")

CODEC_TMDB_KEY = ""
CODEC_FANART_KEY = ""

# codec's own Cast receiver, once codec has one of its own: the App ID the
# Google Cast developer console gives it, and the public https address it is
# registered to (where scripts/codec_receiver_export.py's page is hosted). A
# TV runs it to show codec's face and play Dolby Vision; a person's own
# party.castAppId wins, and with neither, Google's plain receiver is used.
CODEC_CAST_APP = "C30E2505"
CODEC_RECEIVER_URL = "https://ciphernovaa.github.io/codec/cast/receiver/"


def settings():
    try:
        with open(CFG) as f:
            return json.load(f).get("settings", {}) or {}
    except (OSError, ValueError):
        return {}


def tmdb_key(s=None):
    s = settings() if s is None else s
    return (s.get("tmdbApiKey") or "").strip() or CODEC_TMDB_KEY


def fanart_enabled(s=None):
    s = settings() if s is None else s
    return s.get("fanartArt", True) is not False


def fanart_key(s=None):
    s = settings() if s is None else s
    return (s.get("fanartApiKey") or "").strip() or CODEC_FANART_KEY


def fanart_query(s=None):
    """The fanart.tv query string: codec's (or your) project key, plus your
    personal key when you've set one. "" when there's no key at all."""
    s = settings() if s is None else s
    key = fanart_key(s)
    if not key:
        return ""
    q = "api_key=" + key
    personal = (s.get("fanartPersonalKey") or "").strip()
    if personal:
        q += "&client_key=" + personal
    return q


def cast_app_id(cfg=None):
    """The receiver a cast launches: config party.castAppId, else codec's own,
    else "" (the caller falls back to Google's Default Media Receiver)."""
    if cfg is None:
        try:
            with open(CFG) as f:
                cfg = json.load(f)
        except (OSError, ValueError):
            cfg = {}
    aid = str(((cfg.get("party") or {}).get("castAppId") or "")).strip().upper()
    return aid or CODEC_CAST_APP


def _adopt_mine():
    """Make this machine's own config keys codec's built-in ones (rewrites the
    two constants above). The person running it decides that — it's their key."""
    s = settings()
    tk = (s.get("tmdbApiKey") or "").strip()
    fk = (s.get("fanartApiKey") or "").strip()
    src = open(__file__).read()
    src = re.sub(r'^CODEC_TMDB_KEY = ".*"$', 'CODEC_TMDB_KEY = "%s"' % tk, src, count=1, flags=re.M)
    src = re.sub(r'^CODEC_FANART_KEY = ".*"$', 'CODEC_FANART_KEY = "%s"' % fk, src, count=1, flags=re.M)
    with open(__file__, "w") as f:
        f.write(src)
    print("codec's built-in keys now: tmdb %s · fanart %s" % ("set" if tk else "EMPTY", "set" if fk else "EMPTY"))


if __name__ == "__main__":
    if "--adopt-mine" in sys.argv[1:]:
        _adopt_mine()
        sys.exit(0)
    s = settings()
    print("built in:", "tmdb" if CODEC_TMDB_KEY else "no tmdb", "·",
          "fanart" if CODEC_FANART_KEY else "no fanart")
    print("tmdb:", "your key" if (s.get("tmdbApiKey") or "").strip()
          else ("codec's key" if CODEC_TMDB_KEY else "NONE"))
    print("fanart:", "off" if not fanart_enabled(s) else
          ("your project key" if (s.get("fanartApiKey") or "").strip()
           else ("codec's key" if CODEC_FANART_KEY else "NONE"))
          + (" + your personal key" if (s.get("fanartPersonalKey") or "").strip() else ""))
