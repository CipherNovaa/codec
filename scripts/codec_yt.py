#!/usr/bin/env python3
"""Codec YouTube worker — yt-dlp behind a JSON-lines protocol.

Runs as a QProcess child of the app: one JSON request per stdin line, one
JSON reply per stdout line (same id). Isolates yt-dlp (crashes, updates,
latency) from the C++ process; the app restarts it freely — all state lives
in the app.

Requests:
  {"id": 1, "op": "search", "q": "armored core lore"}
  {"id": 2, "op": "browse", "tab": "playlists" | "subs" | "watchlater" |
                                   "history" | "rec"}
  {"id": 3, "op": "browse", "url": "https://.../playlist?list=..."}
  {"id": 4, "op": "wl_add", "videoId": "..."}          # add to Watch Later
  {"id": 5, "op": "pl_add", "videoId": "...", "playlistId": "PL..."}
  {"id": 6, "op": "playlists_flat"}   # [{title,id}] for the add-to picker
Replies:
  {"id": N, "ok": true, "entries": [...], "context": "<list title>"}
  {"id": N, "ok": false, "error": "..."}

Writes (watch later / playlist add) go through YouTube's InnerTube API
authenticated with the same browser cookies (SAPISIDHASH) — yt-dlp itself
is read-only.

Two ways to do YouTube (config youtube.mode, Settings ▸ YOUTUBE):
  account  YouTube's own feeds, through a browser's login — the profile named
           by youtube.cookiesFromBrowser (a yt-dlp spec; codec_ytaccount.py
           finds the candidates), else the best signed-in one found
  local    codec's own lists, no account (codec_ytlocal.py) — a new
           install's start
The worker announces which, and who is signed in, as an "account" event at
start and after every change ({"op": "connect" | "use_local"}).
"""
import json
import os
import re
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import codec_ytaccount as ytacct
import codec_ytlocal
import codec_ytpage

CFG = Path.home() / ".config/codec/config.json"
OAUTH_TOKENS = Path.home() / ".config/codec/youtube-oauth.json"

# ── YouTube Data API v3 OAuth (the ONLY reliable way to SEND live chat) ──────
# The reverse-engineered InnerTube send_message is BotGuard-gated (400s
# always). The official Data API's liveChatMessages.insert works with a normal
# OAuth token — this is what Nightbot/StreamElements use. Setup is one-time:
# the user makes their own Google Cloud OAuth "Desktop" client, drops the
# id/secret in config, and runs `codec_yt.py --auth` once. See docs/CHAT.md.
OAUTH_SCOPE = "https://www.googleapis.com/auth/youtube.force-ssl"
OAUTH_AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
OAUTH_TOKEN_URL = "https://oauth2.googleapis.com/token"
DATA_API = "https://www.googleapis.com/youtube/v3"


def _oauth_client():
    """(client_id, client_secret) from config, or (None, None)."""
    if not CFG.exists():
        return (None, None)
    yt = json.loads(CFG.read_text()).get("youtube", {})
    return (yt.get("oauthClientId"), yt.get("oauthClientSecret"))


def _oauth_post(data):
    import urllib.parse
    import urllib.request
    req = urllib.request.Request(
        OAUTH_TOKEN_URL, urllib.parse.urlencode(data).encode(),
        {"Content-Type": "application/x-www-form-urlencoded"})
    return json.loads(urllib.request.urlopen(req, timeout=30).read())


def oauth_authorize():
    """One-time: open the consent screen, catch the localhost redirect, store
    the refresh token. Prints progress as JSON events on stdout."""
    import http.server
    import secrets
    import threading
    import urllib.parse
    import webbrowser
    cid, csecret = _oauth_client()
    if not cid or not csecret:
        send({"ok": False, "error": "set youtube.oauthClientId + "
              "oauthClientSecret in ~/.config/codec/config.json first"})
        return
    # Loopback flow: a throwaway localhost server catches ?code=.
    holder = {}
    ev = threading.Event()

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            q = urllib.parse.urlparse(self.path).query
            holder.update(urllib.parse.parse_qs(q))
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(b"<html><body style='font-family:sans-serif;"
                             b"background:#111;color:#eee;text-align:center;"
                             b"padding-top:20vh'><h2>codec is connected to "
                             b"YouTube.</h2><p>You can close this tab.</p>"
                             b"</body></html>")
            ev.set()

        def log_message(self, *a):
            pass

    srv = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    port = srv.server_address[1]
    redirect = f"http://127.0.0.1:{port}"
    state = secrets.token_urlsafe(16)
    auth = OAUTH_AUTH_URL + "?" + urllib.parse.urlencode({
        "client_id": cid, "redirect_uri": redirect, "response_type": "code",
        "scope": OAUTH_SCOPE, "access_type": "offline",
        # Always show the account chooser — the user may have several Google
        # accounts and only one has the YouTube channel that can chat.
        "prompt": "select_account consent", "state": state})
    send({"event": "auth_url", "url": auth})
    try:
        webbrowser.open(auth)
    except Exception:
        pass
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    if not ev.wait(timeout=300):
        send({"ok": False, "error": "timed out waiting for authorization"})
        return
    srv.shutdown()
    if holder.get("state", [""])[0] != state or "code" not in holder:
        send({"ok": False, "error": "authorization failed or was denied"})
        return
    try:
        tok = _oauth_post({"code": holder["code"][0], "client_id": cid,
                           "client_secret": csecret, "redirect_uri": redirect,
                           "grant_type": "authorization_code"})
    except Exception as e:
        send({"ok": False, "error": "token exchange failed: " + str(e)[:150]})
        return
    if "refresh_token" not in tok:
        send({"ok": False, "error": "no refresh token returned — remove codec "
              "from account permissions and retry"})
        return
    OAUTH_TOKENS.parent.mkdir(parents=True, exist_ok=True)
    OAUTH_TOKENS.write_text(json.dumps({"refresh_token": tok["refresh_token"]}))
    OAUTH_TOKENS.chmod(0o600)
    send({"ok": True, "event": "authorized"})


def _access_token():
    """Fresh access token from the stored refresh token, or None."""
    cid, csecret = _oauth_client()
    if not cid or not csecret or not OAUTH_TOKENS.exists():
        return None
    rt = json.loads(OAUTH_TOKENS.read_text()).get("refresh_token")
    if not rt:
        return None
    tok = _oauth_post({"client_id": cid, "client_secret": csecret,
                       "refresh_token": rt, "grant_type": "refresh_token"})
    return tok.get("access_token")


def _api_get(path, params, token):
    import urllib.parse
    import urllib.request
    url = DATA_API + path + "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={
        "Authorization": "Bearer " + token})
    return json.loads(urllib.request.urlopen(req, timeout=20).read())


def _live_chat_id(video_id, token):
    d = _api_get("/videos", {"part": "liveStreamingDetails",
                             "id": video_id}, token)
    items = d.get("items") or []
    if not items:
        return ""
    return (items[0].get("liveStreamingDetails", {})
            .get("activeLiveChatId", ""))


def chat_send_api(video_id, text):
    """Send via the official Data API. Returns True on success, raises with a
    human message otherwise."""
    import urllib.error
    import urllib.request
    token = _access_token()
    if not token:
        raise RuntimeError("__NO_OAUTH__")  # caller decides the message
    chat_id = _live_chat_id(video_id, token)
    if not chat_id:
        raise RuntimeError("this video has no active live chat")
    body = json.dumps({"snippet": {
        "liveChatId": chat_id, "type": "textMessageEvent",
        "textMessageDetails": {"messageText": text}}}).encode()
    req = urllib.request.Request(
        DATA_API + "/liveChat/messages?part=snippet", body,
        {"Authorization": "Bearer " + token,
         "Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=20).read()
        return True
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = json.loads(e.read()).get("error", {}).get("message", "")
        except Exception:
            pass
        if e.code == 403 and "quota" in detail.lower():
            raise RuntimeError("youtube api quota reached for today")
        raise RuntimeError(detail or f"send failed (HTTP {e.code})")


TABS = {
    "playlists": "https://www.youtube.com/feed/playlists",
    "subs": ":ytsubs",
    "watchlater": ":ytwatchlater",
    "history": ":ythistory",
    "rec": ":ytrec",
}
AUTH_TABS = {"playlists", "subs", "watchlater", "history", "rec"}


import threading as _threading

_send_lock = _threading.Lock()


def send(obj):
    with _send_lock:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()


try:
    from yt_dlp import YoutubeDL
except ImportError:
    # Imported by the hub (codec_serve) it must not take the server down:
    # only the worker itself announces the missing engine and stops.
    YoutubeDL = None
    if __name__ == "__main__":
        import codec_paths   # this distro's install line
        send({"event": "fatal",
              "error": "yt-dlp not installed — " + codec_paths.install_hint("yt-dlp")})
        sys.exit(1)


COOKIE_CACHE = Path.home() / ".cache/codec/ytcookies.txt"


# ── which login ─────────────────────────────────────────────────────────────
def yt_config():
    try:
        return json.loads(CFG.read_text()).get("youtube") or {}
    except (OSError, ValueError, AttributeError):
        return {}


def mode():
    """"account" (a browser's YouTube login) or "local" (codec's own lists)."""
    y = yt_config()
    if y.get("mode") in ("account", "local"):
        return y["mode"]
    # From before codec asked: a machine that named a browser, or whose codec
    # has been reading the browser's login all along (its cookie copy exists),
    # stays on its account; a new install starts on codec's own lists.
    return "account" if (y.get("cookiesFromBrowser") or COOKIE_CACHE.exists()) else "local"


_BEST = {"spec": "", "ts": 0.0}


def login_spec():
    """The yt-dlp browser spec of the login in use — what mpv and the hub's
    yt-dlp are handed too — or "" (codec's own lists, or no browser)."""
    import time as _time
    if mode() != "account":
        return ""
    spec = (yt_config().get("cookiesFromBrowser") or "").strip()
    if spec:
        head, sep, prof = spec.partition(":")
        if prof.startswith("~"):
            spec = head + sep + str(Path(prof).expanduser())
        return spec
    # None named: the best signed-in profile here (looked up at most a minute
    # apart — the hub asks on every yt-dlp run).
    if _time.time() - _BEST["ts"] > 60:
        best = ytacct.best_profile()
        _BEST.update(spec=best["spec"] if best else "", ts=_time.time())
    return _BEST["spec"]


def cookies_spec():
    """yt-dlp's cookiesfrombrowser tuple (browser, profile, keyring,
    container) for the login in use, or None for anonymous."""
    return ytacct.parse_spec(login_spec())


def save_youtube(**kv):
    """Set keys of the config's youtube section — under the lock the app and
    every helper share (config.json.lock), read fresh, swapped in whole."""
    import fcntl
    CFG.parent.mkdir(parents=True, exist_ok=True)
    with open(str(CFG) + ".lock", "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        try:
            cfg = json.loads(CFG.read_text()) if CFG.exists() else {}
        except (OSError, ValueError):
            cfg = {}
        y = cfg.setdefault("youtube", {})
        for k, v in kv.items():
            if v is None:
                y.pop(k, None)
            else:
                y[k] = v
        tmp = CFG.with_suffix(CFG.suffix + ".tmp")
        tmp.write_text(json.dumps(cfg, indent=4))
        tmp.replace(CFG)
    _BEST["ts"] = 0.0


# ── cookie cache ────────────────────────────────────────────────────────────
# Extracting cookies from the browser's sqlite is the hidden tax on EVERY
# request (yt-dlp listing + date fetch each paid it separately). Extract once,
# serve from memory, refresh every few minutes (YouTube rotates PSIDTS).
_COOKIES = {"jar": None, "ts": 0.0, "spec": None}
_COOKIE_TTL = 180


_cookie_lock = _threading.Lock()


def cookie_file():
    """Path to a Netscape cookie file mirroring the browser, refreshed at most
    every _COOKIE_TTL seconds. One sqlite extraction serves every consumer.
    Locked: requests now run concurrently, and two threads refreshing at once
    would both write the same .part file."""
    with _cookie_lock:
        return _cookie_file_locked()


def _cookie_file_locked():
    import time as _time
    now = _time.time()
    spec = login_spec()
    if (_COOKIES["jar"] is not None and _COOKIES["spec"] == spec
            and now - _COOKIES["ts"] <= _COOKIE_TTL):
        return COOKIE_CACHE if (_COOKIES["jar"] and COOKIE_CACHE.exists()) else None
    _COOKIES["spec"] = spec
    if not spec:
        _COOKIES["jar"] = False
        _COOKIES["ts"] = now
        return None
    try:
        # Only YouTube's and Google's cookies, read with Firefox's -wal
        # (codec_ytaccount.load_cookies) — the copy used to hold every site's.
        jar, used = ytacct.load_cookies(spec)
        if used != spec and yt_config().get("cookiesFromBrowser"):
            save_youtube(cookiesFromBrowser=used)   # the keyring that unlocked it
            _COOKIES["spec"] = used
        COOKIE_CACHE.parent.mkdir(parents=True, exist_ok=True)
        # Atomic: jar.save() truncates+rewrites in place, so a concurrent
        # describe thread could load a half-written cookie file. Save to a temp
        # and rename it in.
        tmp = COOKIE_CACHE.with_suffix(".part")
        jar.save(str(tmp), ignore_discard=True, ignore_expires=True)
        tmp.chmod(0o600)
        tmp.replace(COOKIE_CACHE)
        _COOKIES["jar"] = jar
        _COOKIES["ts"] = now
        return COOKIE_CACHE
    except Exception:
        _COOKIES["jar"] = False
        _COOKIES["ts"] = now
        return None


# yt-dlp's message when the (cached) cookies have gone stale — YouTube rotates
# __Secure-*PSIDTS every few minutes, so a jar cached even a short while can read
# as logged-OUT and yt-dlp demands a fresh "sign in", the "log in and refresh in
# browser" bug the user hits WITH youtube.com open. Re-extracting from the live
# browser gets the rotated cookies and the retry succeeds.
_AUTH_ERR_MARKERS = ("sign in", "log in", "confirm you", "not a bot",
                     "cookies", "authenticat", "consent")
# Errors about the CONTENT, which fresh cookies can't fix. "account" matched
# "This account has been terminated", and a members-only or private video
# matched too: each cost a browser cookie re-extract, a full re-run, and then
# a false "sign-in expired — open youtube.com" message hiding the real one.
_CONTENT_ERR_MARKERS = ("terminated", "members-only", "members only",
                        "join this channel", "private video", "been removed",
                        "video unavailable", "not available in your country")


def is_auth_error(e):
    m = str(e).lower()
    return (any(k in m for k in _AUTH_ERR_MARKERS)
            and not any(k in m for k in _CONTENT_ERR_MARKERS))


def refresh_cookies():
    """Force the NEXT extraction to re-read the browser, bypassing the TTL cache —
    the recovery lever for a stale-PSIDTS 'sign in' error."""
    _COOKIES["jar"] = None
    _COOKIES["ts"] = 0.0


def yt_cookies():
    """{name: value} — auth-relevant youtube.com cookies ONLY. The full jar
    in one Cookie: header overflowed YouTube's limit (HTTP 413)."""
    cookie_file()
    jar = _COOKIES["jar"]
    if not jar:
        return {}
    return ytacct.yt_cookie_dict(jar)


# The channel the login acts as (ytacct.session): without its X-Goog-PageId a
# write lands on the plain Google account — "Subscription added", and the
# channel's own lists (what yt-dlp reads) never show it. Kept per login; the
# browser can switch channel, so it is read again every 10 minutes.
_SESSION = {"key": None, "ts": 0.0, "v": {}}
_SESSION_TTL = 600
_session_lock = _threading.Lock()


def yt_session(fresh=False):
    import time as _time
    ck = yt_cookies()
    key = ck.get("SAPISID") or ck.get("__Secure-3PAPISID")
    if not key:
        return {}
    with _session_lock:
        if (not fresh and _SESSION["key"] == key
                and _time.time() - _SESSION["ts"] < _SESSION_TTL):
            return _SESSION["v"]
        try:
            v = ytacct.session(ck)
        except Exception:
            # Unread, the last one this login had beats acting as the plain
            # account; a first read that fails is tried again next call.
            return _SESSION["v"] if _SESSION["key"] == key else {}
        _SESSION.update(key=key, ts=_time.time(), v=v)
        return v


# ── the account, as the app shows it ────────────────────────────────────────
class NotSignedIn(RuntimeError):
    """A read or write that needs the account, with none to use. `kind` says
    which case, so the app shows the right way out."""
    def __init__(self, kind, msg):
        super().__init__(msg)
        self.kind = kind


def _browser_word():
    return ytacct.label_of(login_spec()) or "your browser"


def need_login(why="that"):
    """Raise the honest NotSignedIn for the state the login is in."""
    if mode() != "account":
        raise NotSignedIn("local", f"{why} needs a YouTube account — connect one "
                          "in Settings ▸ YouTube")
    if not login_spec():
        raise NotSignedIn("nobrowser", "no browser here is signed into YouTube — "
                          "sign in on youtube.com in one, or use codec's own "
                          "lists in Settings ▸ YouTube")
    b = _browser_word()
    raise NotSignedIn("signedout", f"{b} isn't signed into YouTube — sign in on "
                      f"youtube.com in {b}, then press F5")


_ACCOUNT = {"v": None, "ts": 0.0}
_ACCOUNT_FILE = Path.home() / ".cache/codec/yt-account.json"
# Working out the account and switching it take turns: the start-up
# announcement, computed across a CONNECT, landed after it with the old mode
# and a half-read login ("signed out").
_ACCOUNT_LOCK = _threading.RLock()


def engine():
    """What YouTube runs on here: yt-dlp's version, and the JavaScript
    runtime yt-dlp needs for YouTube's checks (since late 2025)."""
    import shutil
    try:
        from yt_dlp.version import __version__ as ver
    except ImportError:
        ver = ""
    js = next((r for r in ("deno", "node", "bun", "qjs") if shutil.which(r)), "")
    return {"ytdlp": ver, "js": js}


def account_state(fresh=False):
    """{mode, state, browser, profile, spec, name, handle, photo, engine}.
    state: local · connected · expired (YouTube refuses the browser's login)
    · signedout (the browser isn't signed in) · nobrowser · offline (couldn't
    ask YouTube; the last known account is kept)."""
    with _ACCOUNT_LOCK:
        return _account_state(fresh)


def _account_state(fresh):
    import time as _time
    if not fresh and _ACCOUNT["v"] and _time.time() - _ACCOUNT["ts"] < 600:
        return _ACCOUNT["v"]
    st = {"mode": mode(), "engine": engine()}
    if st["mode"] == "local":
        st.update(state="local", local=LOCAL.snapshot())
    else:
        spec = login_spec()
        st["spec"] = spec
        st["browser"] = ytacct.label_of(spec)
        p = ytacct.parse_spec(spec)
        st["profile"] = Path(p[1]).name if p and p[1] else ""
        if not spec:
            st["state"] = "nobrowser"
        else:
            if fresh:
                refresh_cookies()
            ck = yt_cookies()
            if not (ck.get("SAPISID") or ck.get("__Secure-3PAPISID")):
                st["state"] = "signedout"
            else:
                try:
                    who = ytacct.identity(ck, yt_session(fresh))
                    st.update(who or {}, state="connected" if who else "expired")
                    if who:
                        try:
                            _ACCOUNT_FILE.write_text(json.dumps(dict(who, spec=spec)))
                        except OSError:
                            pass
                except Exception:
                    st["state"] = "offline"
                    try:
                        last = json.loads(_ACCOUNT_FILE.read_text())
                        if last.get("spec") == spec:
                            st.update({k: last.get(k, "") for k in ("name", "handle", "photo")})
                    except (OSError, ValueError):
                        pass
    _ACCOUNT.update(v=st, ts=_time.time())
    return st


def announce_account(fresh=True):
    """Tell the app who YouTube is now (an "account" event)."""
    try:
        with _ACCOUNT_LOCK:
            send(dict(account_state(fresh), event="account"))
    except Exception as e:
        send({"event": "account", "state": "offline", "mode": mode(),
              "error": str(e)[:200]})


_PROFILES = {"v": None, "ts": 0.0}


def profiles_with_names(fresh=False):
    """Every browser profile here, each signed-in one with the account it
    signs in as — the CONNECT YOUTUBE rows."""
    import time as _time
    from concurrent.futures import ThreadPoolExecutor
    if not fresh and _PROFILES["v"] is not None and _time.time() - _PROFILES["ts"] < 300:
        return _PROFILES["v"]
    profs = ytacct.find_profiles()

    def who(p):
        if not p["signedIn"]:
            return p
        try:
            jar, used = ytacct.load_cookies(p["spec"])
            ck = ytacct.yt_cookie_dict(jar)
            if not (ck.get("SAPISID") or ck.get("__Secure-3PAPISID")):
                p["locked"] = True          # a Chrome login its keyring wouldn't open
                return p
            ident = ytacct.identity(ck)
            if ident:
                p.update(ident, spec=used)
            else:
                p["expired"] = True
        except Exception:
            p["offline"] = True
        return p
    with ThreadPoolExecutor(max_workers=6) as ex:
        profs = list(ex.map(who, profs))
    _PROFILES.update(v=profs, ts=_time.time())
    return profs


def mkdl(auth, start=0):
    opts = {
        "quiet": True,
        "no_warnings": True,
        "noprogress": True,
        "skip_download": True,
        # Bound the network ops: without it a stalled googlevideo/InnerTube
        # request hangs the (serially-processing) worker indefinitely.
        "socket_timeout": 20,
        "extract_flat": "in_playlist",
        "playlist_items": f"{start + 1}-{start + 40}",
    }
    if auth:
        cf = cookie_file()
        if cf:
            opts["cookiefile"] = str(cf)
    return YoutubeDL(opts)


def fmt_dur(s):
    s = int(s or 0)
    if s <= 0:
        return ""
    if s >= 3600:
        return f"{s // 3600}:{s % 3600 // 60:02d}:{s % 60:02d}"
    return f"{s // 60}:{s % 60:02d}"


def innertube(endpoint, body, need_auth=True):
    """Call YouTube's internal API. With browser cookies it authenticates via
    SAPISIDHASH (required for WRITES — WL/playlists); reads that merely want
    richer data (upload dates) pass need_auth=False and fall back to an
    anonymous call when not signed in. Signed calls act as the login's
    channel (yt_session)."""
    cookies = yt_cookies()
    sapisid = cookies.get("SAPISID") or cookies.get("__Secure-3PAPISID")
    if not sapisid and need_auth:
        need_login()
    if not sapisid:
        return ytacct.innertube(endpoint, body, timeout=20)
    return ytacct.innertube(endpoint, body, cookies, timeout=20, sess=yt_session())


# Page URLs whose ytInitialData carries upload dates for each feed tab.
DATE_PAGE_URLS = {
    "subs": "https://www.youtube.com/feed/subscriptions",
    "rec": "https://www.youtube.com/",
    "watchlater": "https://www.youtube.com/playlist?list=WL",
    "history": "https://www.youtube.com/feed/history",
}


def _page_data(url):
    """ytInitialData of a YouTube page fetched with the browser cookies.
    The HTML page reflects the account's SELECTED channel identity; the bare
    InnerTube API does not (it served a different profile's subs in testing),
    so dates come from the exact page yt-dlp scraped."""
    import re as _re
    import urllib.request
    cookies = yt_cookies()
    req = urllib.request.Request(url, headers={
        "User-Agent": ("Mozilla/5.0 (X11; Linux x86_64; rv:132.0) "
                       "Gecko/20100101 Firefox/132.0"),
        "Accept-Language": "en-US,en;q=0.9",
        "Cookie": "; ".join(f"{k}={v}" for k, v in cookies.items()),
    })
    html = urllib.request.urlopen(req, timeout=25).read().decode("utf-8", "replace")
    m = _re.search(r"ytInitialData\s*=\s*({.*?});</script>", html, _re.S)
    return json.loads(m.group(1)) if m else {}


def fetch_date_data(page_url=None, query=None):
    """The network half of date enrichment — run it CONCURRENTLY with the
    yt-dlp listing (threads), the wall clock pays max() not sum()."""
    try:
        if query is not None:
            return innertube("search", {"query": query}, need_auth=False)
        if page_url:
            return _page_data(page_url)
    except Exception:
        pass
    return None


def apply_dates(entries, data):
    """Stamp entries with YouTube's own upload-date strings ('3 weeks ago'),
    matched back by videoId across every renderer generation."""
    if data is None or not any(e.get("kind") == "video" for e in entries):
        return entries
    import re as _re
    found = {}

    def from_lockup(lv):
        # New-style feeds (subs/rec) carry lockupViewModel: contentId +
        # metadata text parts, one of which reads "N days ago".
        vid = lv.get("contentId")
        if not isinstance(vid, str) or vid in found:
            return
        stk = [lv.get("metadata")]
        while stk:
            o = stk.pop()
            if isinstance(o, dict):
                c = o.get("content")
                if isinstance(c, str) and _re.search(r"\bago\b", c):
                    found[vid] = c.replace("Streamed ", "")
                    return
                stk.extend(o.values())
            elif isinstance(o, list):
                stk.extend(o)

    stack = [data]
    while stack:
        o = stack.pop()
        if isinstance(o, dict):
            vid = o.get("videoId")
            if isinstance(vid, str) and vid not in found:
                # Classic renderers (search results, channel pages).
                pt = o.get("publishedTimeText")
                if isinstance(pt, dict):
                    txt = pt.get("simpleText") or "".join(
                        r.get("text", "") for r in pt.get("runs", []))
                    if txt:
                        found[vid] = txt
                # Playlist rows pack "views · date" into videoInfo runs.
                vi = o.get("videoInfo")
                if vid not in found and isinstance(vi, dict):
                    for r in vi.get("runs", []):
                        t = r.get("text", "")
                        if _re.search(r"\bago\b", t):
                            found[vid] = t.replace("Streamed ", "")
                            break
            lv = o.get("lockupViewModel")
            if isinstance(lv, dict):
                from_lockup(lv)
            stack.extend(o.values())
        elif isinstance(o, list):
            stack.extend(o)
    for e in entries:
        p = found.get(e.get("videoId"))
        if p:
            e["published"] = p
    return entries


def _txt(o):
    if not isinstance(o, dict):
        return ""
    return o.get("simpleText") or "".join(
        r.get("text", "") for r in o.get("runs", []))


def search_entries(data, limit=40):
    """MediaItems straight from an InnerTube search response — one ~0.5s call
    carrying titles, durations, views AND dates, instead of a multi-second
    yt-dlp extraction plus a second call for dates. Returns [] on any shape
    surprise; the caller falls back to the yt-dlp path."""
    return search_page(data)[0][:limit]


def _cont_token(item):
    try:
        return (item["continuationItemRenderer"]["continuationEndpoint"]
                ["continuationCommand"]["token"])
    except Exception:
        return ""


def search_page(data):
    """(entries, continuation token) for an InnerTube search response — the
    first page OR a continuation page. Paging by continuation costs one ~0.5s
    call per page at ANY depth; the old yt-dlp `ytsearchN` path re-extracted
    from result 0 every time and was capped at 40, so page 3+ came back empty."""
    secs = []
    try:
        secs = (data["contents"]["twoColumnSearchResultsRenderer"]
                ["primaryContents"]["sectionListRenderer"]["contents"])
    except Exception:
        for cmd in data.get("onResponseReceivedCommands") or []:
            secs += ((cmd.get("appendContinuationItemsAction") or {})
                     .get("continuationItems") or [])
    out, cont = [], ""
    for sec in secs:
        cont = _cont_token(sec) or cont
        for item in (sec.get("itemSectionRenderer") or {}).get("contents", []):
            e = (_video_item(item.get("videoRenderer"))
                 or _channel_item(item.get("channelRenderer"))
                 or _playlist_item(item.get("playlistRenderer"))
                 or _lockup_item(item.get("lockupViewModel")))
            if e:
                out.append(e)
    return out, cont


def _channel_item(cr):
    if not cr or not cr.get("channelId"):
        return None
    url = "https://www.youtube.com/channel/" + cr["channelId"]
    try:
        url = "https://www.youtube.com" + cr["navigationEndpoint"][
            "browseEndpoint"]["canonicalBaseUrl"]
    except Exception:
        pass
    thumbs = (cr.get("thumbnail") or {}).get("thumbnails") or []
    art = thumbs[-1]["url"] if thumbs else ""
    if art.startswith("//"):
        art = "https:" + art
    subs = _txt(cr.get("videoCountText")) or _txt(cr.get("subscriberCountText"))
    return {"uri": url, "title": _txt(cr.get("title")) or "(channel)",
            "subtitle": " · ".join(x for x in ("CHANNEL", subs) if x),
            "artUrl": art, "durationS": 0.0, "kind": "channel",
            "sourceId": "youtube", "videoId": "", "channelUrl": url,
            "published": "", "isLive": False}


def _playlist_item(pr):
    if not pr or not pr.get("playlistId"):
        return None
    pid = pr["playlistId"]
    art = ""
    try:
        art = pr["thumbnails"][0]["thumbnails"][-1]["url"]
    except Exception:
        pass
    owner = _txt(pr.get("longBylineText") or pr.get("shortBylineText"))
    count = pr.get("videoCount") or ""
    return {"uri": f"https://www.youtube.com/playlist?list={pid}",
            "title": _txt(pr.get("title")) or "(playlist)",
            "subtitle": " · ".join(x for x in (
                "PLAYLIST", owner, f"{count} videos" if count else "") if x),
            "artUrl": art, "durationS": 0.0, "kind": "playlist",
            "sourceId": "youtube", "videoId": "", "channelUrl": "",
            "published": "", "isLive": False}


def _lockup_item(lv):
    """YouTube's newer lockup card — playlists and mixes arrive in this shape
    (the old playlistRenderer is gone from search)."""
    if not lv or not lv.get("contentId"):
        return None
    ctype = lv.get("contentType", "")
    if "PLAYLIST" not in ctype and "ALBUM" not in ctype:
        return None
    pid = lv["contentId"]
    meta = (lv.get("metadata") or {}).get("lockupMetadataViewModel") or {}
    title = (meta.get("title") or {}).get("content") or "(playlist)"
    parts = []
    try:
        for row in meta["metadata"]["contentMetadataViewModel"]["metadataRows"]:
            for part in row.get("metadataParts") or []:
                t = (part.get("text") or {}).get("content")
                if t and t not in ("Playlist", "•"):
                    parts.append(t)
    except Exception:
        pass
    art, count = "", ""
    try:
        thumb = (lv["contentImage"]["collectionThumbnailViewModel"]
                 ["primaryThumbnail"]["thumbnailViewModel"])
        art = thumb["image"]["sources"][-1]["url"]
        for ov in thumb.get("overlays") or []:
            for b in ((ov.get("thumbnailOverlayBadgeViewModel") or {})
                      .get("thumbnailBadges") or []):
                count = (b.get("thumbnailBadgeViewModel") or {}).get("text") or count
    except Exception:
        pass
    return {"uri": f"https://www.youtube.com/playlist?list={pid}",
            "title": title,
            "subtitle": " · ".join(x for x in ["PLAYLIST"] + parts[:1] + [count] if x),
            "artUrl": art, "durationS": 0.0, "kind": "playlist",
            "sourceId": "youtube", "videoId": "", "channelUrl": "",
            "published": "", "isLive": False}


def find_all(o, key, limit=500):
    """Every value stored under `key` anywhere in an InnerTube response."""
    out, stack = [], [o]
    while stack and len(out) < limit:
        x = stack.pop()
        if isinstance(x, dict):
            if key in x:
                out.append(x[key])
            stack.extend(reversed(list(x.values())))
        elif isinstance(x, list):
            stack.extend(reversed(x))
    return out


_AGO_UNITS = {"s": "second", "m": "minute", "h": "hour", "d": "day", "w": "week",
              "mo": "month", "y": "year"}


def _long_ago(t):
    """'5h ago' (the compact card's wording) → '5 hours ago', as every other
    row says it."""
    m = re.fullmatch(r"(\d+)\s*(mo|[smhdwy])\s+ago", (t or "").strip())
    if not m:
        return t
    n = int(m.group(1))
    return f"{n} {_AGO_UNITS[m.group(2)]}{'s' if n != 1 else ''} ago"


def _video_lockup_item(lv):
    """A VIDEO in YouTube's newer lockup card — the shape a watch page's
    suggestions and a channel's Videos tab now arrive in."""
    if not lv or lv.get("contentType") != "LOCKUP_CONTENT_TYPE_VIDEO":
        return None
    vid = lv.get("contentId") or ""
    if not vid:
        return None
    meta = (lv.get("metadata") or {}).get("lockupMetadataViewModel") or {}
    title = (meta.get("title") or {}).get("content") or "(untitled)"
    rows = (((meta.get("metadata") or {}).get("contentMetadataViewModel") or {})
            .get("metadataRows") or [])
    parts = [[(p.get("text") or {}).get("content", "") for p in r.get("metadataParts") or []]
             for r in rows]
    channel = parts[0][0] if parts and parts[0] else ""
    line2 = [t for t in (parts[1] if len(parts) > 1 else []) if t]
    viewtxt = next((t for t in line2 if "view" in t or "watching" in t
                    or t[:1].isdigit() and "ago" not in t), "")
    if viewtxt and "view" not in viewtxt and "watching" not in viewtxt:
        viewtxt += " views"
    published = _long_ago(next((t.replace("Streamed ", "") for t in line2 if "ago" in t), ""))
    length, live, short = "", False, False
    thumb = ((lv.get("contentImage") or {}).get("thumbnailViewModel") or {})
    for ov in thumb.get("overlays") or []:
        for b in (((ov.get("thumbnailBottomOverlayViewModel") or {}).get("badges") or [])
                  + ((ov.get("thumbnailOverlayBadgeViewModel") or {}).get("thumbnailBadges") or [])):
            bv = b.get("thumbnailBadgeViewModel") or {}
            t = bv.get("text") or ""
            if "LIVE" in (bv.get("badgeStyle") or "") or t.upper() == "LIVE":
                live = True
            elif re.fullmatch(r"\d+(:\d\d)+", t):
                length = t
    dur = 0
    for part in length.split(":"):
        if part.isdigit():
            dur = dur * 60 + int(part)
    churl = ""
    for u in find_all(meta.get("image") or {}, "canonicalBaseUrl", 1):
        churl = "https://www.youtube.com" + u
    if not churl:
        for b in find_all(meta.get("image") or {}, "browseId", 1):
            churl = "https://www.youtube.com/channel/" + b
    if "/shorts/" in json.dumps((lv.get("rendererContext") or {}).get("commandContext") or {}):
        short = True
    return {
        "uri": f"https://www.youtube.com/watch?v={vid}", "title": title,
        "subtitle": " · ".join(x for x in (channel, length, viewtxt) if x),
        "artUrl": f"https://i.ytimg.com/vi/{vid}/mqdefault.jpg",
        "durationS": float(dur), "kind": "video", "sourceId": "youtube",
        "videoId": vid, "channelUrl": churl, "channel": channel,
        "published": published, "isLive": live, "isShort": short,
    }


def _video_item(vr):
    if not vr or not vr.get("videoId"):
        return None
    vid = vr["videoId"]
    length = _txt(vr.get("lengthText"))
    dur = 0
    for part in length.split(":"):
        if part.isdigit():
            dur = dur * 60 + int(part)
    # Live now: the LIVE badge or a LIVE time-status overlay (live
    # streams carry no lengthText).
    live = False
    for b in vr.get("badges") or []:
        if (b.get("metadataBadgeRenderer") or {}).get("style") \
                == "BADGE_STYLE_TYPE_LIVE_NOW":
            live = True
    for ov in vr.get("thumbnailOverlays") or []:
        if (ov.get("thumbnailOverlayTimeStatusRenderer") or {}) \
                .get("style") == "LIVE":
            live = True
    ch = _txt(vr.get("ownerText") or vr.get("longBylineText"))
    views = _txt(vr.get("shortViewCountText"))
    if live and views and "watching" not in views:
        views += " watching"
    churl = ""
    try:
        churl = "https://www.youtube.com" + \
            (vr.get("ownerText") or {})["runs"][0][
                "navigationEndpoint"]["browseEndpoint"][
                "canonicalBaseUrl"]
    except Exception:
        pass
    short = "/shorts/" in json.dumps(vr.get("navigationEndpoint") or {})
    return {
        "uri": f"https://www.youtube.com/watch?v={vid}",
        "title": _txt(vr.get("title")) or "(untitled)",
        "subtitle": " · ".join(x for x in (ch, length, views) if x),
        "artUrl": f"https://i.ytimg.com/vi/{vid}/mqdefault.jpg",
        "durationS": float(dur), "kind": "video",
        "sourceId": "youtube", "videoId": vid, "channelUrl": churl,
        "published": _txt(vr.get("publishedTimeText")),
        "isLive": live, "isShort": short,
    }


def playlist_edit(playlist_id, action):
    playlist_edits(playlist_id, [action])


def playlist_edits(playlist_id, actions):
    """Several edits to one playlist in one request (select mode's ADD /
    REMOVE), 50 to a request."""
    for i in range(0, len(actions), 50):
        r = innertube("browse/edit_playlist",
                      {"playlistId": playlist_id, "actions": actions[i:i + 50]})
        if r.get("status") != "STATUS_SUCCEEDED":
            raise RuntimeError(f"youtube said {r.get('status', 'nothing')}")


def playlist_add(video_id, playlist_id):
    playlist_edit(playlist_id,
                  {"addedVideoId": video_id, "action": "ACTION_ADD_VIDEO"})


def playlist_remove(video_id, playlist_id):
    playlist_edit(playlist_id,
                  {"removedVideoId": video_id,
                   "action": "ACTION_REMOVE_VIDEO_BY_VIDEO_ID"})


def norm(e):
    """Flat yt-dlp entry -> MediaItem-shaped dict."""
    vid = e.get("id", "")
    url = e.get("url") or e.get("webpage_url") or ""
    kind = "video"
    if "playlist?list=" in url:
        kind = "playlist"
    elif "/@" in url or "/channel/" in url:
        kind = "channel"
    # A Short arrives as …/shorts/ID — remember it before the url is rewritten
    # to the canonical watch?v= (the row shows a SHORT tag; it plays like any video).
    short = "/shorts/" in url
    if kind == "video" and vid:
        url = f"https://www.youtube.com/watch?v={vid}"
    channel = e.get("channel") or e.get("uploader") or ""
    if channel == "View full playlist":     # yt-dlp's read of a playlist card's link
        channel = ""
    dur = e.get("duration") or 0
    sub = " · ".join(x for x in (channel, fmt_dur(dur)) if x)
    views = e.get("view_count")
    if views:
        sub += f" · {views:,} views"
    thumbs = e.get("thumbnails") or []
    thumb = thumbs[-1]["url"] if thumbs else \
        (f"https://i.ytimg.com/vi/{vid}/mqdefault.jpg" if kind == "video" and vid else "")
    if thumb.startswith("//"):               # a channel's avatar comes protocol-relative
        thumb = "https:" + thumb
    if kind == "channel":
        # its handle and followers, not its name again
        fol = e.get("channel_follower_count")
        sub = " · ".join(x for x in (e.get("uploader_id") or "",
                                     codec_ytlocal.views(fol).replace("views", "subscribers")
                                     .replace("view", "subscriber") if fol else "") if x)
    return {
        "uri": url, "title": e.get("title") or "(untitled)", "subtitle": sub,
        "artUrl": thumb, "durationS": float(dur), "kind": kind,
        "sourceId": "youtube", "videoId": vid,
        "channelUrl": e.get("channel_url") or e.get("uploader_url") or "",
        "published": "",  # filled by add_dates; keep the key so QML sees a string
        "isLive": e.get("live_status") == "is_live",
        "isShort": short,
    }


def entries_of(info):
    if info.get("_type") == "playlist" or "entries" in info:
        return [norm(e) for e in (info.get("entries") or []) if e]
    return [norm(info)]


# ── search filters ──────────────────────────────────────────────────────────
# YouTube's filter panel is a tiny protobuf, base64'd into the `sp` URL param —
# the same value InnerTube's search endpoint takes as `params`. Field numbers
# are what youtube.com itself sends (stable for years):
#   1 sort: 0 relevance · 1 rating · 2 upload date · 3 view count
#   2 filters { 1 upload date: 1 hour · 2 today · 3 week · 4 month · 5 year
#               2 type: 1 video · 2 channel · 3 playlist · 4 movie
#               3 duration: 1 under 4 min · 2 over 20 min · 3 4-20 min
#               8 live: 1 }
_SORT = {"rating": 1, "date": 2, "views": 3}
_DATE = {"hour": 1, "today": 2, "week": 3, "month": 4, "year": 5}
_TYPE = {"video": 1, "channel": 2, "playlist": 3, "movie": 4}
_DUR = {"short": 1, "long": 2, "medium": 3}


def _pb(fields):
    """Encode [(field, int|bytes)] as protobuf: varints and nested messages."""
    out = bytearray()
    for num, val in fields:
        if isinstance(val, (bytes, bytearray)):
            out.append((num << 3) | 2)
            out.append(len(val))
            out += val
        else:
            out.append(num << 3)
            while True:
                b = val & 0x7F
                val >>= 7
                out.append(b | (0x80 if val else 0))
                if not val:
                    break
    return bytes(out)


def search_params(f):
    """InnerTube `params` for a filter dict {sort, date, type, duration, live};
    "" when nothing is set (plain relevance search)."""
    import base64
    inner = []
    if f.get("date") in _DATE:
        inner.append((1, _DATE[f["date"]]))
    if f.get("type") in _TYPE:
        inner.append((2, _TYPE[f["type"]]))
    if f.get("duration") in _DUR:
        inner.append((3, _DUR[f["duration"]]))
    if f.get("live"):
        inner.append((8, 1))
    outer = []
    if f.get("sort") in _SORT:
        outer.append((1, _SORT[f["sort"]]))
    if inner:
        outer.append((2, _pb(inner)))
    return base64.b64encode(_pb(outer)).decode() if outer else ""


# Per-query paging state: everything fetched so far plus the next continuation
# token, so page N costs one call however deep N is.
_SEARCHES = {}
_search_locks = {}
_search_locks_guard = _threading.Lock()


def _query_lock(key):
    """One lock PER QUERY: a single global lock held across the network call
    let a prefetch for the previous query stall a brand-new search."""
    with _search_locks_guard:
        lk = _search_locks.get(key)
        if lk is None:
            lk = _search_locks[key] = _threading.Lock()
            if len(_search_locks) > 60:
                _search_locks.pop(next(iter(_search_locks)))
        return lk


def search_slice(q, params, start, n=40):
    import time as _time
    key = (q, params)
    with _query_lock(key):
        st = _SEARCHES.get(key)
        if start == 0 or not st or _time.time() - st["ts"] > 600:
            body = {"query": q}
            if params:
                body["params"] = params
            entries, cont = search_page(innertube("search", body, need_auth=False))
            st = {"entries": entries, "cont": cont, "ts": _time.time()}
            _SEARCHES[key] = st
            if len(_SEARCHES) > 30:
                _SEARCHES.pop(next(iter(_SEARCHES)))
        # Fetch only until there is SOMETHING past `start` — page 1 answers
        # with YouTube's first page (~20) at once; the app's prefetch pulls the
        # next continuation while that page is being read.
        while len(st["entries"]) <= start and st["cont"]:
            more, st["cont"] = search_page(innertube(
                "search", {"continuation": st["cont"]}, need_auth=False))
            if not more:
                break
            st["entries"] += more
        return (st["entries"][start:start + n],
                bool(st["cont"]) or len(st["entries"]) > start + n)


# ── result cache ────────────────────────────────────────────────────────────
# Every listing used to be fetched fresh: switching tabs, backing out of a
# channel, reopening YouTube all paid the full 1-2.5s again. Listings are
# cached for a few minutes (YouTube's own pages are no fresher than that), a
# prefetch op warms the NEXT page while the current one is read, and a request
# for a key already in flight waits for that fetch instead of starting another.
_CACHE_TTL = 300
_CACHED_OPS = {"search", "browse", "playlists_flat"}
_cache = {}
_gen = {}            # listing (key without its page offset) -> generation of its page 0
_inflight = {}
_cache_lock = _threading.Lock()


def _cache_key(req):
    keep = {k: req.get(k) for k in ("op", "tab", "url", "q", "start", "filters")
            if req.get(k) not in (None, "", 0, {})}
    return json.dumps(keep, sort_keys=True)


def cache_invalidate(*tabs):
    """Drop cached listings for these tabs (or everything) after a write."""
    with _cache_lock:
        for k in list(_cache):
            if not tabs or any(f'"tab": "{t}"' in k for t in tabs) \
                    or "playlists_flat" in k:
                _cache.pop(k, None)


def _listing_key(req):
    """The cache key with the page offset removed — every page of a listing."""
    return _cache_key(dict(req, start=0))


def cache_drop_containing(fragment):
    """Drop cached listings whose key mentions `fragment` (e.g. a playlist id —
    a drilled playlist is cached under its url, not under a tab)."""
    if not fragment:
        return
    with _cache_lock:
        for k in list(_cache):
            if fragment in k:
                _cache.pop(k, None)


def handle_cached(req):
    import time as _time
    if req.get("op") not in _CACHED_OPS:
        return handle(req)
    key = _cache_key(req)
    base = _listing_key(req)
    first = int(req.get("start") or 0) == 0
    if req.get("fresh"):
        # A refresh re-reads the WHOLE listing: later pages cached before it
        # would splice old rows onto the new first page (dupes / gaps).
        base = _listing_key(req)
        with _cache_lock:
            for k in list(_cache):
                if _listing_key(json.loads(k)) == base:
                    _cache.pop(k, None)
        if req.get("op") == "search":
            _SEARCHES.pop((req.get("q", "").strip(),
                           search_params(req.get("filters") or {})), None)
    with _cache_lock:
        hit = _cache.get(key)
        # A LATER page counts only if it belongs to the current page 0 (same
        # generation). Otherwise rows of an older listing got spliced onto a
        # re-fetched first page — a prefetch racing F5, or page 3 outliving
        # pages 1-2 because its TTL started later — and rows went missing.
        gen = _gen.get(base, 0)
        if (hit and not req.get("fresh") and _time.time() - hit[0] < _CACHE_TTL
                and (first or hit[2] == gen)):
            return dict(hit[1], cached=True)
        ev = _inflight.get(key)
        owner = ev is None
        if owner:
            ev = _inflight[key] = _threading.Event()
            if first:                         # a new page 0 = a new listing
                if len(_gen) > 1000:
                    _gen.clear()
                gen = _gen[base] = gen + 1
    if not owner:
        ev.wait(60)
        with _cache_lock:
            hit = _cache.get(key)
        if hit:
            return dict(hit[1], cached=True)
        return handle(req)
    try:
        rep = handle(req)
        if rep.get("ok"):
            with _cache_lock:
                _cache[key] = (_time.time(), rep, gen)
                if len(_cache) > 200:
                    _cache.pop(next(iter(_cache)))
        return rep
    finally:
        with _cache_lock:
            _inflight.pop(key, None)
        ev.set()


LOCAL = codec_ytlocal.Local(sys.modules[__name__])

_FOLLOWING = {"ids": [], "ts": 0.0}


def following_ids(fresh=False):
    """The channel ids followed — the account's subscriptions or codec's own
    list — so a menu can offer SUBSCRIBE or UNSUBSCRIBE (cached 10 min)."""
    import time as _time
    if mode() == "local":
        return [c["id"] for c in LOCAL.following()]
    if fresh or _time.time() - _FOLLOWING["ts"] > 600:
        ids = [e.get("channel_id") or e.get("id")
               for e in whole_feed("https://www.youtube.com/feed/channels")]
        ids = [i for i in ids if (i or "").startswith("UC")]
        _FOLLOWING.update(ids=ids, ts=_time.time())
    return _FOLLOWING["ids"]


def _followed(cid, on):
    """What a SUBSCRIBE / UNSUBSCRIBE just did, kept as the list: YouTube's
    own list lags the write by seconds, and read back at once it showed the
    channel still followed (the menu offered UNSUBSCRIBE again)."""
    import time as _time
    ids = [i for i in following_ids() if i != cid]
    if on:
        ids.insert(0, cid)
    _FOLLOWING.update(ids=ids, ts=_time.time())
    return ids


# Playlists made here, until YouTube's own list shows them (~10 s after):
# [(ts, playlistId, row)]. Opened at once, PLAYLISTS and the picker missed it.
_MADE = []


def made_playlists(present):
    """The playlists made here that YouTube's list doesn't have yet (rows),
    newest first. `present` = the ids it listed."""
    import time as _time
    now = _time.time()
    _MADE[:] = [m for m in _MADE if now - m[0] < 300 and m[1] not in present]
    return [m[2] for m in reversed(_MADE)]


def _list_id(uri):
    return uri.split("list=", 1)[1].split("&", 1)[0] if "list=" in (uri or "") else ""


_PAGE_POOL = ThreadPoolExecutor(max_workers=4)


def _special_row(uri, title, line):
    """A row of codec's own that opens a list (SUBS' ALL CHANNELS,
    NOTIFICATIONS) — kind "list" drills like a playlist."""
    return {"uri": uri, "title": title, "subtitle": line, "kind": "list", "artUrl": "",
            "durationS": 0.0, "sourceId": "youtube", "videoId": "", "channelUrl": "",
            "published": "", "isLive": False, "isShort": False}


def unseen_count():
    try:
        d = innertube("notification/get_unseen_count", {})
        n = find_all(d, "unseenCount", 1)
        return int(n[0]) if n else None
    except Exception:
        return None


def subs_extras(local, unseen=None):
    """SUBS opens on rows of its own: every channel followed, and with an
    account the notification inbox."""
    n = len(following_ids()) if (local or _FOLLOWING["ts"]) else 0
    rows = [_special_row("codec:channels", "All channels",
                         f"{n} followed" if n else "every channel you follow")]
    if not local:
        # (opening them here marks them seen, as YouTube's own bell does)
        rows.append(_special_row("codec:notifications", "Notifications",
                                 "what YouTube has told you" if unseen is None
                                 else f"{unseen} new" if unseen else "nothing new"))
    return rows


_NOTIF = {"next": ""}


def codec_list(url, start, local):
    """The lists SUBS opens: ALL CHANNELS (every one followed, A–Z) and
    NOTIFICATIONS (the account's inbox, paged by YouTube's token)."""
    if url == "codec:channels":
        if start > 0:
            return {"ok": True, "entries": [], "more": False, "context": "All channels"}
        if local:
            rows = [{"uri": "https://www.youtube.com/channel/" + c["id"], "title": c.get("title") or c["id"],
                     "subtitle": "", "kind": "channel", "artUrl": "", "durationS": 0.0,
                     "sourceId": "youtube", "videoId": c["id"],
                     "channelUrl": "https://www.youtube.com/channel/" + c["id"], "published": "",
                     "isLive": False, "isShort": False} for c in LOCAL.following()]
        else:
            rows = [norm(e) for e in whole_feed("https://www.youtube.com/feed/channels")]
        rows.sort(key=lambda r: r["title"].casefold())
        n = len(rows)
        return {"ok": True, "entries": rows, "more": False, "context": "All channels",
                "note": "" if rows else "NO CHANNELS FOLLOWED YET",
                "header": {"kind": "list", "title": "All channels", "url": url,
                           "count": n, "noun": "CHANNEL"}}
    if local:
        need_login("notifications")
    if start == 0:
        d = innertube("browse", {"browseId": "FEnotifications_inbox"})
    elif _NOTIF["next"]:
        d = innertube("browse", {"continuation": _NOTIF["next"]})
    else:
        return {"ok": True, "entries": [], "more": False, "context": "Notifications"}
    rows = []
    for n in find_all(d, "notificationRenderer"):
        vid = ((n.get("navigationEndpoint") or {}).get("watchEndpoint") or {}).get("videoId", "")
        hide = notif_hide_token(n)
        runs = [r.get("text", "") for r in (n.get("shortMessage") or {}).get("runs") or []]
        title = runs[-1] if len(runs) >= 3 else "".join(runs)
        who = "".join(runs[:-1]).strip().rstrip(":") if len(runs) >= 3 else ""
        thumbs = ((n.get("videoThumbnail") or {}).get("thumbnails") or [])
        rows.append({"uri": f"https://www.youtube.com/watch?v={vid}" if vid else "",
                     "title": title, "subtitle": who, "kind": "video" if vid else "list",
                     "artUrl": thumbs[-1]["url"] if thumbs else "", "durationS": 0.0,
                     "sourceId": "youtube", "videoId": vid, "channelUrl": "",
                     "published": ("NEW · " if not n.get("read") else "") + _txt(n.get("sentTimeText")),
                     "isLive": False, "isShort": "/shorts/" in json.dumps(n.get("navigationEndpoint") or {}),
                     "hideToken": hide})
    toks = find_all(find_all(d, "continuationItemRenderer"), "token", 1)
    _NOTIF["next"] = toks[0] if toks else ""
    out = {"ok": True, "entries": [r for r in rows if r["uri"]], "more": bool(_NOTIF["next"]),
           "context": "Notifications", "note": "" if rows else "NO NOTIFICATIONS"}
    if start == 0:
        out["header"] = {"kind": "list", "title": "Notifications", "url": url}
    return out


def batch(req, local):
    """Select mode: one action on many rows. Where YouTube takes a list it
    gets one request (unsubscribe takes channelIds, a playlist edit takes
    actions); codec's own lists change in one write each."""
    action, pid = req.get("action", ""), req.get("playlistId", "")
    items = [i for i in req.get("items") or [] if isinstance(i, dict)]
    vids = [i.get("videoId") for i in items if i.get("kind", "video") == "video" and i.get("videoId")]
    out = {"ok": True, "action": action, "count": 0}
    if action in ("wl_add", "wl_remove", "pl_add", "pl_remove"):
        target = "WL" if action.startswith("wl") else pid
        own = local or target.startswith("cpl") or target == codec_ytlocal.LIKED_ID
        adding = action.endswith("add")
        if own:
            for it in items:
                if not it.get("videoId"):
                    continue
                if action == "wl_add":
                    LOCAL.wl_add(it)
                elif action == "wl_remove":
                    LOCAL.wl_remove(it["videoId"])
                elif adding:
                    LOCAL.pl_add(target, it)
                else:
                    LOCAL.pl_remove(target, it["videoId"])
        else:
            playlist_edits(target, [{"addedVideoId": v, "action": "ACTION_ADD_VIDEO"} if adding else
                                    {"removedVideoId": v, "action": "ACTION_REMOVE_VIDEO_BY_VIDEO_ID"}
                                    for v in vids])
        cache_invalidate("watchlater", "playlists")
        cache_drop_containing("list=" + target)
        cache_drop_containing("codec:playlist:" + target)
        out["count"] = len(vids)
    elif action in ("subscribe", "unsubscribe"):
        import time as _time
        on = action == "subscribe"
        named = {}                           # channel id -> its name
        for it in items:
            chan = it.get("kind") == "channel"
            url = it.get("uri") if chan else it.get("channelUrl")
            cid = (it.get("videoId") if chan and (it.get("videoId") or "").startswith("UC")
                   else LOCAL.resolve_channel(url or ""))
            if cid:
                named.setdefault(cid, it.get("title", "") if chan else it.get("channel", ""))
        cids = list(named)
        if local:
            for cid in cids:
                (LOCAL.subscribe(cid, named[cid]) if on else LOCAL.unsubscribe(cid))
            out["following"] = following_ids()
        else:
            for i in range(0, len(cids), 50):
                innertube(f"subscription/{action}", {"channelIds": cids[i:i + 50]})
            ids = [x for x in following_ids() if x not in cids] + (cids if on else [])
            _FOLLOWING.update(ids=ids, ts=_time.time())
            out["following"] = ids
        cache_invalidate("subs", "rec")
        cache_drop_containing("codec:channels")
        out["count"] = len(cids)
    elif action == "unlike":
        for it in items:
            if not it.get("videoId"):
                continue
            if local:
                LOCAL.rate(it, "")
            else:
                innertube("like/removelike", {"target": {"videoId": it["videoId"]}})
        cache_drop_containing("list=LL")
        cache_drop_containing("codec:playlist:" + codec_ytlocal.LIKED_ID)
        out["count"] = len(vids)
    elif action in ("history_remove", "hide"):
        if not local:
            raise RuntimeError("that's only for codec's own lists")
        for v in vids:
            (LOCAL.history_remove(v) if action == "history_remove" else LOCAL.hide(v))
        cache_invalidate("history" if action == "history_remove" else "rec")
        out["count"] = len(vids)
    elif action == "notif_hide":
        out["count"] = notif_hide([i.get("hideToken", "") for i in items])
        cache_drop_containing("codec:notifications")
    else:
        return {"ok": False, "error": f"no batch {action!r}"}
    return out


def notif_hide_token(n):
    """A notification's "Hide this notification" — the only removal YouTube
    offers (its bell has no clear-all; CLEAR ALL here hides every one)."""
    for it in ((n.get("contextualMenu") or {}).get("menuRenderer") or {}).get("items") or []:
        ep = ((it.get("menuServiceItemRenderer") or {}).get("serviceEndpoint") or {})
        rec = ep.get("recordNotificationInteractionsEndpoint") or {}
        if rec.get("serializedInteractionsRequest") and "Hide" in _txt(
                (it.get("menuServiceItemRenderer") or {}).get("text")):
            return rec["serializedInteractionsRequest"]
    return ""


def notif_hide(tokens):
    """Hide notifications by their hide tokens — one a request (the plural
    field YouTube's schema has answers 400), eight at once."""
    tokens = [t for t in tokens if t]

    def one(t):
        innertube("notification/record_interactions",
                  {"serializedRecordNotificationInteractionsRequest": t})
    with ThreadPoolExecutor(max_workers=8) as ex:
        list(ex.map(one, tokens))
    return len(tokens)


def notif_clear(max_pages=20):
    """CLEAR ALL: every notification in the inbox, hidden (page by page — the
    inbox holds a few hundred at most)."""
    tokens, d = [], innertube("browse", {"browseId": "FEnotifications_inbox"})
    for _ in range(max_pages):
        tokens += [notif_hide_token(n) for n in find_all(d, "notificationRenderer")]
        nxt = find_all(find_all(d, "continuationItemRenderer"), "token", 1)
        if not nxt:
            break
        d = innertube("browse", {"continuation": nxt[0]})
    _NOTIF["next"] = ""
    return notif_hide(tokens)


def listing_header(info, url):
    """What heads a drilled listing: a channel's picture, banner, handle and
    followers, or a playlist's title, length and owner (yt-dlp's own read of
    the page, no extra request)."""
    thumbs = {t.get("id"): t.get("url", "") for t in info.get("thumbnails") or []}
    if "list=" in url:
        return {"kind": "playlist", "title": info.get("title") or "",
                "id": _list_id(url), "url": url,
                "count": int(info.get("playlist_count") or 0),
                "owner": info.get("channel") or info.get("uploader") or "",
                "ownerUrl": info.get("channel_url") or info.get("uploader_url") or "",
                "description": info.get("description") or ""}
    if not info.get("channel_id"):
        return None
    square = [t for t in info.get("thumbnails") or [] if t.get("width") and t.get("width") == t.get("height")]
    wide = [t for t in info.get("thumbnails") or [] if (t.get("width") or 0) > 2 * (t.get("height") or 1)]
    return {"kind": "channel", "title": info.get("channel") or info.get("uploader") or "",
            "channelId": info["channel_id"],
            "url": "https://www.youtube.com/channel/" + info["channel_id"],
            "handle": info.get("uploader_id") or "",
            "followers": int(info.get("channel_follower_count") or 0),
            "avatar": thumbs.get("avatar_uncropped") or (square[-1]["url"] if square else ""),
            "banner": (wide[-1]["url"] if wide else "") or thumbs.get("banner_uncropped", ""),
            "description": info.get("description") or ""}


def whole_feed(url):
    """Every entry of an account feed, in one flat read — mkdl pages by 40,
    and the channel list stopped at the 40th channel, the playlist picker at
    the 40th playlist."""
    cf = cookie_file()
    if not (cf and yt_cookies()):
        return []
    info = YoutubeDL({"quiet": True, "no_warnings": True, "skip_download": True,
                      "extract_flat": "in_playlist", "socket_timeout": 20,
                      "cookiefile": str(cf)}).extract_info(url, download=False)
    return info.get("entries") or []


_ACCOUNT_OPS = {"account", "profiles", "connect", "use_local", "import", "import_takeout",
                "takeout"}


def handle_account(req):
    """Settings ▸ YOUTUBE: who is signed in, the browsers that could be, and
    switching between them and codec's own lists."""
    import tempfile
    op = req["op"]
    if op == "account":
        return {"ok": True, "account": account_state(bool(req.get("fresh")))}
    if op == "profiles":
        t = LOCAL.find_takeout()
        return {"ok": True, "profiles": profiles_with_names(bool(req.get("fresh"))),
                "takeout": t.name if t else ""}
    if op in ("connect", "use_local"):
        spec = (req.get("spec") or "").strip()
        if op == "connect" and not ytacct.parse_spec(spec):
            return {"ok": False, "error": "no browser named"}
        with _ACCOUNT_LOCK:
            if op == "connect":
                save_youtube(mode="account", cookiesFromBrowser=spec)
            else:
                save_youtube(mode="local")
            refresh_cookies()
            cache_invalidate()
            _FOLLOWING["ts"] = 0.0
            _SESSION["ts"] = 0.0
            st = account_state(fresh=True)
            send(dict(st, event="account"))
        return {"ok": True, "account": st}
    if op == "takeout":
        # is there a Google Takeout to import (Settings ▸ YOUTUBE's row)?
        t = LOCAL.find_takeout()
        return {"ok": True, "takeout": t.name if t else ""}
    if op == "import_takeout":
        added = LOCAL.import_takeout(req.get("path") or None, lambda m: send(
            {"event": "import", "id": req.get("id"), "status": m}))
        cache_invalidate()
        _ACCOUNT["ts"] = 0.0
        return {"ok": True, "added": added, "local": LOCAL.snapshot()}
    if op == "import":
        # Copy a signed-in profile's subscriptions, playlists and Watch Later
        # into codec's own lists (the account itself is only read).
        spec = req.get("spec") or login_spec()
        if not spec:
            best = ytacct.best_profile()
            spec = best["spec"] if best else ""
        if not spec:
            raise NotSignedIn("nobrowser", "no browser here is signed into YouTube")
        jar, _ = ytacct.load_cookies(spec)
        if not ytacct.yt_cookie_dict(jar).get("SAPISID"):
            raise NotSignedIn("signedout", f"{ytacct.label_of(spec)} isn't signed into YouTube")
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
            path = f.name
        try:
            jar.save(path, ignore_discard=True, ignore_expires=True)
            os.chmod(path, 0o600)
            added = LOCAL.import_from(path, lambda m: send(
                {"event": "import", "id": req.get("id"), "status": m}))
        finally:
            os.unlink(path)
        cache_invalidate()
        _ACCOUNT["ts"] = 0.0
        return {"ok": True, "added": added, "local": LOCAL.snapshot()}
    return {"ok": False, "error": f"unknown op {op!r}"}


def handle(req):
    op = req.get("op", "")
    start = max(0, int(req.get("start") or 0))
    if op == "search":
        q = req.get("q", "").strip()
        if not q:
            return {"ok": True, "entries": [], "context": ""}
        params = search_params(req.get("filters") or {})
        try:
            entries, more = search_slice(q, params, start)
            if entries or start > 0 or params:
                return {"ok": True, "entries": entries, "context": q,
                        "more": more}
        except Exception:
            if params:
                raise
        if start == 0:
            # Fast path: one InnerTube call = results + dates (~0.5s).
            try:
                entries = search_entries(
                    innertube("search", {"query": q}, need_auth=False))
            except Exception:
                entries = []
            if len(entries) >= 5:
                return {"ok": True, "entries": entries, "context": q}
        # Fallback / deep pages: fetch through the target and slice.
        info = mkdl(auth=False, start=0).extract_info(
            f"ytsearch{start + 40}:{q}", download=False)
        entries = entries_of(info)[start:]
        if start == 0:
            apply_dates(entries, fetch_date_data(query=q))
        return {"ok": True, "entries": entries, "context": q}
    if op in _ACCOUNT_OPS:
        return handle_account(req)
    local = mode() == "local"
    if op == "browse" and (req.get("url") or "") in ("codec:channels", "codec:notifications"):
        return codec_list(req["url"], start, local)
    # codec's own playlists are codec's whichever way YouTube is reached now
    # (one pinned as a tab, then an account connected)
    if op == "browse" and ((local and req.get("tab") in AUTH_TABS)
                           or (req.get("url") or "").startswith("codec:playlist:")):
        # codec's own lists (codec_ytlocal) — no account to ask
        tab, url = req.get("tab", ""), req.get("url") or ""
        fresh = bool(req.get("fresh"))
        if url:
            pid = url.split(":", 2)[2]
            rows, more, title = LOCAL.playlist_page(pid, start)
            out = {"ok": True, "entries": rows, "more": more, "context": title}
            if start == 0:
                out["header"] = {"kind": "playlist", "title": title, "id": pid, "owner": "",
                                 "count": LOCAL.playlist_count(pid), "url": url}
            return out
        if tab == "subs":
            rows, more, note = LOCAL.subs_page(start, fresh=fresh)
            if start == 0 and rows:
                rows = subs_extras(True) + rows
        elif tab == "rec":
            rows, more, note = LOCAL.rec_page(start, fresh=fresh)
        else:
            rows, more, note = LOCAL.list_page(tab, start)
        return {"ok": True, "entries": rows, "more": more, "context": tab, "note": note}
    if op == "browse":
        url = req.get("url") or TABS.get(req.get("tab", ""), "")
        if not url:
            return {"ok": False, "error": f"unknown tab {req.get('tab')!r}"}
        auth = req.get("tab") in AUTH_TABS or "url" in req
        if req.get("tab") in AUTH_TABS and not yt_cookies():
            need_login("this list")
        holder = {}
        t = None
        # SUBS' NOTIFICATIONS row says how many are new — read beside the list
        unseen = (_PAGE_POOL.submit(unseen_count)
                  if req.get("tab") == "subs" and start == 0 else None)
        if start == 0:
            page = DATE_PAGE_URLS.get(req.get("tab", "")) \
                or (url if url.startswith("http") else "")
            if page:
                # Date page downloads WHILE yt-dlp lists — parallel, not serial.
                import threading as _threading
                t = _threading.Thread(
                    target=lambda: holder.update(
                        d=fetch_date_data(page_url=page)))
                t.start()
        try:
            info = mkdl(auth=auth, start=start).extract_info(url, download=False)
        except Exception as e:
            if not (auth and is_auth_error(e)):
                raise
            # The "log in and refresh in browser" bug: the cached jar rotated out.
            # Re-extract from the live browser and retry once before giving up.
            refresh_cookies()
            try:
                info = mkdl(auth=auth, start=start).extract_info(url, download=False)
            except Exception as e2:
                if not is_auth_error(e2):
                    raise
                b = _browser_word()
                raise NotSignedIn("expired", f"{b}'s YouTube sign-in has run out — "
                                  f"open youtube.com in {b} (that signs it back in), "
                                  "then press F5")
        entries = entries_of(info)
        if t:
            t.join(timeout=10)
            apply_dates(entries, holder.get("d"))
        if req.get("tab") == "playlists" and start == 0:
            entries[:0] = made_playlists({_list_id(e.get("uri")) for e in entries})
        # yt-dlp is asked for 40 (playlist_items), but feed pages routinely
        # come back a few short (35-39) mid-feed — only a page that is mostly
        # empty means the end. (">= 40" ended For You after its first page.)
        more = len(entries) >= 20
        if req.get("tab") == "subs" and start == 0:
            entries[:0] = subs_extras(False, unseen.result(timeout=5) if unseen else None)
        out = {"ok": True, "entries": entries, "more": more,
               "context": info.get("title") or req.get("tab", "")}
        if start == 0 and "url" in req:
            out["header"] = listing_header(info, url)
        return out
    item = req.get("item") or {}
    vid = req.get("videoId") or item.get("videoId") or ""
    if op == "wl_add":
        if local:
            LOCAL.wl_add(item if item.get("title") else LOCAL.video_row(vid))
        else:
            playlist_add(vid, "WL")
        cache_invalidate("watchlater")
        cache_drop_containing("list=WL")     # the drilled PLAYLISTS ▸ Watch later
        return {"ok": True}
    if op == "pl_add":
        pid = req.get("playlistId", "")
        if local or pid.startswith("cpl"):
            LOCAL.pl_add(pid, item if item.get("title") else LOCAL.video_row(vid))
        else:
            playlist_add(vid, pid)
        cache_invalidate("playlists")
        cache_drop_containing(pid)
        return {"ok": True}
    if op == "pl_create":
        # a new playlist, with this video in it (private on an account)
        title = (req.get("title") or "").strip() or "NEW PLAYLIST"
        if local:
            pid = LOCAL.pl_create(title, (item if item.get("title") else LOCAL.video_row(vid))
                                  if vid else None)
        else:
            body = {"title": title, "privacyStatus": "PRIVATE"}
            if vid:
                body["videoIds"] = [vid]
            pid = innertube("playlist/create", body).get("playlistId", "")
            if not pid:
                raise RuntimeError("youtube didn't make the playlist")
            import time as _time
            _MADE.append((_time.time(), pid, norm({
                "url": "https://www.youtube.com/playlist?list=" + pid, "id": pid,
                "title": title, "thumbnails": [{"url": f"https://i.ytimg.com/vi/{vid}/mqdefault.jpg"}]
                if vid else []})))
        cache_invalidate("playlists")
        return {"ok": True, "playlistId": pid, "title": title}
    if op == "pl_remove":
        pid = req.get("playlistId", "")
        if local or pid.startswith("cpl"):
            LOCAL.pl_remove(pid, vid)
        else:
            playlist_remove(vid, pid)
        cache_invalidate("playlists")
        cache_drop_containing(pid)
        return {"ok": True}
    if op == "wl_remove":
        if local:
            LOCAL.wl_remove(vid)
        else:
            playlist_remove(vid, "WL")
        cache_invalidate("watchlater")
        cache_drop_containing("list=WL")     # the drilled PLAYLISTS ▸ Watch later
        return {"ok": True}
    if op == "watch":
        # Account history ping, inside the warm worker: the old per-ping
        # `codec_yt.py --watch` process paid python + yt_dlp import + a cold
        # cookie read every 30 s of playback. codec's own lists keep their
        # history from history_add (the app's note of what it played).
        if not local:
            register_watch(req.get("uri", ""), float(req.get("pos") or 0))
            cache_invalidate("history")
        return {"ok": True}
    if op == "history_add":
        LOCAL.history_add(item)
        if local:
            cache_invalidate("history")
        return {"ok": True}
    if op == "history_remove":
        if not local:
            raise RuntimeError("removing from YouTube's own history isn't here yet")
        LOCAL.history_remove(vid)
        cache_invalidate("history")
        return {"ok": True}
    if op == "hide":
        if not local:
            raise RuntimeError("NOT INTERESTED on YouTube's own feed isn't here yet")
        LOCAL.hide(vid)
        cache_invalidate("rec")
        return {"ok": True}
    if op in ("subscribe", "unsubscribe"):
        ch = req.get("channelUrl") or req.get("channelId") or ""
        if local:
            got = (LOCAL.subscribe(ch, req.get("title", "")) if op == "subscribe"
                   else LOCAL.unsubscribe(ch))
        else:
            cid = LOCAL.resolve_channel(ch)
            if not cid:
                raise RuntimeError("couldn't find that channel")
            r = innertube(f"subscription/{op}", {"channelIds": [cid]})
            if r.get("error"):
                raise RuntimeError("youtube said no")
            got = {"id": cid, "title": req.get("title", "")}
        cache_invalidate("subs", "rec")
        return dict(got, ok=True, following=(following_ids() if local
                                            else _followed(got["id"], op == "subscribe")))
    if op == "all_entries":
        # PLAY ALL / SHUFFLE: a playlist's or channel tab's videos — every one
        # of a playlist, a channel's newest 300
        url = req.get("url") or ""
        if url.startswith("codec:playlist:"):
            rows = LOCAL.playlist_page(url.split(":", 2)[2], 0, 5000)[0]
        else:
            info = YoutubeDL({"quiet": True, "no_warnings": True, "skip_download": True,
                              "extract_flat": "in_playlist", "socket_timeout": 20,
                              "playlistend": 300,
                              **({"cookiefile": str(cookie_file())} if cookie_file() else {})}
                             ).extract_info(url, download=False)
            rows = entries_of(info)
        rows = [r for r in rows if r.get("kind") == "video" and r.get("videoId")]
        return {"ok": True, "entries": rows, "shuffle": bool(req.get("shuffle"))}
    if op == "batch":
        return batch(req, local)
    if op == "notif_hide":
        n = notif_hide(req.get("tokens") or [])
        cache_drop_containing("codec:notifications")
        return {"ok": True, "hidden": n}
    if op == "notif_clear":
        if local:
            need_login("notifications")
        n = notif_clear()
        cache_drop_containing("codec:notifications")
        return {"ok": True, "hidden": n}
    if op == "following":
        return {"ok": True, "ids": following_ids(bool(req.get("fresh")))}
    if op == "playlists_flat":
        if local:
            return {"ok": True, "playlists": LOCAL.playlists_flat()}
        out = []
        feed = whole_feed("https://www.youtube.com/feed/playlists")
        for r in made_playlists({_list_id(e.get("url")) for e in feed}):
            out.append({"title": r["title"], "id": _list_id(r["uri"])})
        for e in feed:
            u = e.get("url") or ""
            if "list=" in u:
                pid = u.split("list=", 1)[1].split("&", 1)[0]
                # WL/LL live in the feed but edit via their own ids anyway.
                out.append({"title": e.get("title") or pid, "id": pid})
        return {"ok": True, "playlists": out}
    if op == "video":
        # the video's own page (codec_ytpage): what's followed and rated is
        # codec's own when there's no account
        page = codec_ytpage.video(sys.modules[__name__], vid)
        if local:
            page["subscribed"] = page.get("channelId", "") in set(following_ids())
            page["rating"] = LOCAL.rating(vid)
        elif page.get("channelId"):
            # the page knows for sure; a list read before a subscribe elsewhere
            # (youtube.com, the phone) catches up from it
            if page["subscribed"] != (page["channelId"] in set(following_ids())):
                _followed(page["channelId"], page["subscribed"])
        return dict(page, ok=True)
    if op == "comments":
        return dict(codec_ytpage.comments(sys.modules[__name__], req.get("token", "")),
                    ok=True, videoId=vid, token=req.get("token", ""))
    if op in ("comment", "comment_like"):
        if local:
            need_login("commenting")
        if op == "comment_like":
            codec_ytpage.like_comment(sys.modules[__name__], req.get("action", ""))
            return {"ok": True, "videoId": vid, "commentId": req.get("commentId", ""),
                    "liked": bool(req.get("liked"))}
        text = (req.get("text") or "").strip()
        if not text:
            return {"ok": False, "error": "nothing to post"}
        cid = codec_ytpage.post(sys.modules[__name__], text, req.get("params", ""), bool(req.get("reply")))
        who = account_state(False)
        return {"ok": True, "videoId": vid, "reply": bool(req.get("reply")),
                "parentId": req.get("parentId", ""),
                "comment": {"id": cid, "author": who.get("handle") or who.get("name") or "you",
                            "avatar": who.get("photo", ""), "text": text, "published": "just now",
                            "likes": "", "replies": 0, "repliesToken": "", "creator": False,
                            "verified": False, "hearted": False, "pinned": False,
                            "reply": bool(req.get("reply")), "mine": True,
                            "replyParams": "", "likeAction": "", "unlikeAction": "", "liked": False}}
    if op == "related_more":
        return dict(codec_ytpage.related(sys.modules[__name__], req.get("token", "")),
                    ok=True, videoId=vid)
    if op == "rate":
        # LIKE / DISLIKE / neither: the account's, or codec's own Liked videos
        status = req.get("status", "")
        if local:
            LOCAL.rate(item if item.get("title") else LOCAL.video_row(vid), status)
            cache_invalidate("playlists")
            cache_drop_containing("codec:playlist:" + codec_ytlocal.LIKED_ID)
        else:
            ep = {"like": "like/like", "dislike": "like/dislike"}.get(status, "like/removelike")
            innertube(ep, {"target": {"videoId": vid}})
            cache_drop_containing("list=LL")
        return {"ok": True, "videoId": vid, "rating": status}
    if op == "suggest":
        # what YouTube's own search box offers for what's typed (~60 ms)
        import urllib.parse
        import urllib.request
        q = req.get("q", "")
        url = ("https://suggestqueries-clients6.youtube.com/complete/search?"
               + urllib.parse.urlencode({"client": "youtube", "ds": "yt", "q": q, "hl": "en"}))
        raw = urllib.request.urlopen(urllib.request.Request(
            url, headers={"User-Agent": "Mozilla/5.0"}), timeout=5).read().decode("utf-8", "replace")
        body = json.loads(raw[raw.index("(") + 1:raw.rindex(")")])
        return {"ok": True, "q": q, "suggestions": [x[0] for x in body[1] if x and x[0]][:10]}
    if op == "describe":
        vid = req.get("videoId", "")
        desc, published = "", ""
        try:
            d = innertube("player", {"videoId": vid}, need_auth=False)
            desc = ((d.get("videoDetails") or {}).get("shortDescription") or "")
            # its date too: a feed's dates are read from its first page only,
            # so a row further down shows its date once it's been selected
            mf = (d.get("microformat") or {}).get("playerMicroformatRenderer") or {}
            when = mf.get("publishDate") or mf.get("uploadDate") or ""
            if when:
                published = codec_ytlocal.ago(codec_ytlocal._iso_ts(when))
        except Exception:
            pass
        return {"ok": True, "videoId": vid, "description": desc[:1500], "published": published}
    if op == "ping":
        return {"ok": True}
    return {"ok": False, "error": f"unknown op {op!r}"}


# ── live chat (--chat <url>) ────────────────────────────────────────────────
# yt-dlp's live-chat downloader polls InnerTube's get_live_chat continuation
# and appends one raw action per line to <out>.live_chat.json until the stream
# ends. It can't stream to stdout, so: download to a temp file, tail it, and
# re-emit each message normalized ({author, message, badges, amount, ts}) as
# a JSON line — the same protocol shape the app already speaks.


_EMOJI_DIR = Path.home() / ".cache/codec/chat-emoji"
_emoji_seen = {}


def _emoji_prune(cap=2000):
    """Custom emojis accumulate one PNG per unique emoji across every live chat
    ever watched, with no eviction. Keep the newest `cap` files."""
    try:
        files = sorted(_EMOJI_DIR.glob("*.png"), key=lambda p: p.stat().st_mtime)
        for p in files[:-cap]:
            p.unlink(missing_ok=True)
    except OSError:
        pass


def _cache_emoji(url):
    """Download a custom channel emoji once, return its local path (or "").
    Cached by URL hash on disk + in-memory so a busy chat re-uses the file."""
    if not url:
        return ""
    if url in _emoji_seen:
        return _emoji_seen[url]
    import hashlib
    import urllib.request
    ext = ".png"
    name = hashlib.sha1(url.encode()).hexdigest()[:16] + ext
    dest = _EMOJI_DIR / name
    if not dest.exists():
        try:
            _EMOJI_DIR.mkdir(parents=True, exist_ok=True)
            data = urllib.request.urlopen(url, timeout=10).read()
            tmp = dest.with_suffix(".part")
            tmp.write_bytes(data)
            tmp.replace(dest)
            _emoji_prune()
        except Exception:
            _emoji_seen[url] = ""
            return ""
    _emoji_seen[url] = str(dest)
    return str(dest)


def _chat_norm(action):
    """One InnerTube chat action -> flat message dict, or None."""
    item = (action.get("addChatItemAction") or {}).get("item") or {}
    text = item.get("liveChatTextMessageRenderer")
    paid = item.get("liveChatPaidMessageRenderer")
    member = item.get("liveChatMembershipItemRenderer")
    src = text or paid or member
    if not src:
        return None
    parts = []
    for run in ((src.get("message") or {}).get("runs")) or []:
        if "text" in run:
            parts.append(run["text"])
        elif "emoji" in run:
            e = run["emoji"]
            # Standard emoji: emojiId IS the unicode char (🌧 😭 ☺). Render it
            # directly — the shortcut (:sob:) is what showed before, unrendered.
            # Custom channel emoji have no codepoint: download the image once
            # and hand back an inline marker \x01<localpath>\x01 the UI turns
            # into an <img>; fall back to the :shortcut: if the fetch fails.
            if e.get("isCustomEmoji"):
                thumbs = (e.get("image") or {}).get("thumbnails") or []
                local = _cache_emoji(thumbs[-1].get("url", "")) if thumbs else ""
                if local:
                    parts.append("\x01" + local + "\x01")
                else:
                    parts.append((e.get("shortcuts") or [""])[0])
            else:
                parts.append(e.get("emojiId")
                             or (e.get("shortcuts") or [""])[0])
    msg = "".join(parts)
    if member and not msg:
        msg = _txt(member.get("headerSubtext")) or "became a member"
    badges = []
    for b in src.get("authorBadges") or []:
        br = b.get("liveChatAuthorBadgeRenderer") or {}
        icon = (br.get("icon") or {}).get("iconType", "")
        if icon == "MODERATOR":
            badges.append("mod")
        elif icon == "VERIFIED":
            badges.append("verified")
        elif icon == "OWNER":
            badges.append("owner")
        elif br.get("customThumbnail"):
            badges.append("member")
    return {"event": "chat",
            "author": _txt(src.get("authorName")),
            "message": msg,
            "badges": badges,
            "amount": _txt(paid.get("purchaseAmountText")) if paid else "",
            "ts": int(src.get("timestampUsec") or 0) // 1000}


def _emit_chat_line(line):
    try:
        o = json.loads(line)
    except json.JSONDecodeError:
        return
    # Live writes raw actions; replays wrap them in replayChatItemAction.
    for a in (o.get("replayChatItemAction") or {}).get("actions") or [o]:
        m = _chat_norm(a)
        if m and (m["author"] or m["message"]):
            send(m)


def chat_main(url):
    import shutil
    import signal
    import tempfile
    import time
    # SIGTERM (app closing the panel) must still reach the finally: raise a
    # normal exit instead of dying mid-loop and stranding the temp dir.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    tmpd = Path(tempfile.mkdtemp(prefix="codec-chat-"))
    opts = {"quiet": True, "no_warnings": True, "noprogress": True,
            "skip_download": True, "writesubtitles": True,
            "subtitleslangs": ["live_chat"], "outtmpl": str(tmpd / "chat")}
    cf = cookie_file()  # members-only chats need the browser session
    if cf:
        opts["cookiefile"] = str(cf)
    done = {}

    def dl():
        try:
            with YoutubeDL(opts) as y:
                y.download([url])
            done["rc"] = 0
        except Exception as e:
            done["rc"] = 1
            send({"event": "error",
                  "error": str(e).replace("\n", " ")[:300]})

    t = _threading.Thread(target=dl, daemon=True)
    t.start()
    send({"event": "ready"})
    # While the stream is live yt-dlp appends to the .part file and only
    # renames on stream end (verified live 2026-07-25) — tail whichever
    # exists; the rename keeps every byte, so the offset carries over.
    final = tmpd / "chat.live_chat.json"
    part = Path(str(final) + ".part")
    pos = 0
    try:
        while True:
            f = part if part.exists() else final
            if f.exists():
                with open(f, encoding="utf-8") as fh:
                    fh.seek(pos)
                    while True:
                        line = fh.readline()
                        if not line.endswith("\n"):
                            break  # partial write — retry next tick
                        pos = fh.tell()
                        _emit_chat_line(line)
            if "rc" in done:
                break
            time.sleep(1.0)
    finally:
        shutil.rmtree(tmpd, ignore_errors=True)
    send({"event": "end"})


# ── send a message to a live chat ───────────────────────────────────────────
# InnerTube live_chat/send_message, authenticated like the WL/playlist writes.
# The send `params` token lives in the FIRST get_live_chat frame's actionPanel
# (it encodes only video+channel, so it never expires); the initial chat
# continuation comes from the `next` endpoint. (Flows reverse-engineered from
# yt-dlp + YouTube.js.)

def _video_id(url_or_id):
    if "watch?v=" in url_or_id:
        return url_or_id.split("watch?v=", 1)[1].split("&", 1)[0]
    if "youtu.be/" in url_or_id:
        return url_or_id.split("youtu.be/", 1)[1].split("?", 1)[0]
    return url_or_id


def _pb_varint(n):
    out = bytearray()
    while True:
        b = n & 0x7f
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def _pb_ld(field, data):  # length-delimited (wire type 2): strings, messages
    return _pb_varint((field << 3) | 2) + _pb_varint(len(data)) + data


def _pb_int(field, val):  # varint (wire type 0)
    return _pb_varint((field << 3) | 0) + _pb_varint(val)


def _send_params(video_id, channel_id):
    """The `params` token live_chat/send_message wants. Encodes only
    channel+video (LiveMessageParams, per YouTube.js protos) so it's stable and
    doesn't depend on YouTube keeping the send endpoint in the chat action
    panel (they moved it out of sendButton — 2026-07). ⚠ It is DOUBLE-encoded:
    base64(protobuf) -> encodeURIComponent -> btoa. A single base64 400s."""
    import base64
    import urllib.parse
    ids = _pb_ld(1, channel_id.encode()) + _pb_ld(2, video_id.encode())
    params = _pb_ld(5, ids)
    msg = _pb_ld(1, params) + _pb_int(2, 1) + _pb_int(3, 4)
    inner = base64.b64encode(msg).decode()          # u8ToBase64
    uri = urllib.parse.quote(inner, safe="")        # encodeURIComponent
    return base64.b64encode(uri.encode()).decode()  # btoa


def chat_send(url_or_id, text):
    import urllib.error
    import uuid
    vid = _video_id(url_or_id)
    # Preferred path: the official Data API (reliable, OAuth). Falls through to
    # the InnerTube attempt only when OAuth isn't set up, so the user gets a
    # "set up sending" nudge rather than a silent nothing.
    try:
        chat_send_api(vid, text)
        return
    except RuntimeError as e:
        if str(e) != "__NO_OAUTH__":
            raise  # a real Data API error (quota, no chat, …) — surface it
    # No OAuth configured: try InnerTube (will 400), then tell the user how to
    # enable reliable sending.
    nxt = innertube("next", {"videoId": vid})
    try:
        cont = (nxt["contents"]["twoColumnWatchNextResults"]["conversationBar"]
                ["liveChatRenderer"]["continuations"][0]
                ["reloadContinuationData"]["continuation"])
    except (KeyError, IndexError):
        raise RuntimeError("live chat is off for this video")
    lc = innertube("live_chat/get_live_chat", {"continuation": cont})
    panel = (lc.get("continuationContents", {}).get("liveChatContinuation", {})
             .get("actionPanel", {}))
    if not panel.get("liveChatMessageInputRenderer"):
        # Restricted (subscribers/members-only, or signed-out) — surface the
        # exact reason YouTube gives instead of a generic failure.
        restricted = panel.get("liveChatRestrictedParticipationRenderer", {})
        why = _txt(restricted.get("message")) or "can't send in this chat"
        raise RuntimeError(why)
    # Broadcaster channelId — needed for the params protobuf.
    channel_id = ""
    try:
        channel_id = innertube("player", {"videoId": vid}, need_auth=False) \
            .get("videoDetails", {}).get("channelId", "")
    except Exception:
        pass
    if not channel_id:
        raise RuntimeError("couldn't resolve the channel to send to")
    try:
        r = innertube("live_chat/send_message", {
            "richMessage": {"textSegments": [{"text": text}]},
            "clientMessageId": str(uuid.uuid4()),
            "params": _send_params(vid, channel_id),
        })
    except urllib.error.HTTPError as e:
        # ⚠ Verified 2026-07-25: YouTube returns 400 INVALID_ARGUMENT for EVERY
        # programmatic send_message (all clients, all param encodings) while the
        # same account's Watch-Later/playlist WRITES succeed — send is gated
        # behind a BotGuard/PoToken browser challenge we can't solve here. So
        # point the user at the reliable Data API path instead.
        if e.code == 400:
            raise RuntimeError("chat send needs one-time setup — run "
                               "'codec_yt.py --auth' (see docs/CHAT.md)")
        raise
    acts = r.get("actions") or []
    for a in acts:  # a real post echoes back as addChatItemAction
        if "addChatItemAction" in a:
            return
    raise RuntimeError("youtube blocked the message (rate limit or verification)")


# ── register a watch into the account's history + resume ─────────────────────
# The videostats playback-tracking pings. The player response (AUTHENTICATED —
# anonymous returns an empty playbackTracking) carries the two ping URLs, which
# already contain docid/ns/len; we merge our params on. Playback ping = history,
# watchtime ping with cmt = the cross-device resume position.
_CPN_ALPHABET = ("abcdefghijklmnopqrstuvwxyz"
                 "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")


def _cpn():
    import random
    return "".join(_CPN_ALPHABET[random.randint(0, 255) & 63] for _ in range(16))


def _videostats_ping(base_url, extra):
    import urllib.parse
    import urllib.request
    u = urllib.parse.urlparse(base_url)
    qs = urllib.parse.parse_qs(u.query)
    qs.update({k: [str(v)] for k, v in extra.items()})
    url = urllib.parse.urlunparse(
        u._replace(query=urllib.parse.urlencode(qs, doseq=True)))
    cookies = yt_cookies()
    req = urllib.request.Request(url, headers={
        "Origin": "https://www.youtube.com",
        "Referer": "https://www.youtube.com/",
        "Cookie": "; ".join(f"{k}={v}" for k, v in cookies.items()),
        "User-Agent": ("Mozilla/5.0 (X11; Linux x86_64; rv:132.0) "
                       "Gecko/20100101 Firefox/132.0"),
    })
    urllib.request.urlopen(req, timeout=15).read()


def register_watch(url_or_id, pos=0.0):
    vid = _video_id(url_or_id)
    pr = innertube("player", {"videoId": vid}, need_auth=True)
    pt = pr.get("playbackTracking", {})
    pb = (pt.get("videostatsPlaybackUrl") or {}).get("baseUrl")
    wt = (pt.get("videostatsWatchtimeUrl") or {}).get("baseUrl")
    if not pb or not wt:
        need_login("watch history")
    cpn = _cpn()
    pos = max(0.0, float(pos))
    # el=detailpage is load-bearing: without it el defaults to "shorts" and the
    # view doesn't count as a normal watch.
    _videostats_ping(pb, {"ver": 2, "cpn": cpn, "cmt": pos, "el": "detailpage"})
    _videostats_ping(wt, {"ver": 2, "cpn": cpn, "cmt": pos, "el": "detailpage",
                          "st": 0, "et": pos})


_HANDLE_IDS = {}       # a channel link (/@handle, /c/…) -> its UC… id


def _channel_key(url):
    u = (url or "").rstrip("/")
    for tab in ("/videos", "/playlists", "/streams", "/shorts", "/featured"):
        if u.endswith(tab):
            u = u[:-len(tab)]
    return u


def _resolve_channels_later(entries):
    """The UC… ids behind a listing's /@handle channel links, looked up after
    the listing has gone out and sent as a "channels" event — so a video's
    menu knows at once whether its channel is followed."""
    from concurrent.futures import ThreadPoolExecutor
    urls = []
    for e in entries or []:
        u = _channel_key(e.get("channelUrl") or "")
        if u and "/channel/UC" not in u and u not in _HANDLE_IDS and u not in urls:
            urls.append(u)
    if not urls:
        return

    def one(u):
        try:
            return u, LOCAL.resolve_channel(u)
        except Exception:
            return u, ""

    def run():
        with ThreadPoolExecutor(max_workers=8) as ex:
            got = {u: cid for u, cid in ex.map(one, urls[:60]) if cid}
        _HANDLE_IDS.update(got)
        if got:
            send({"event": "channels", "ids": got})
    _threading.Thread(target=run, daemon=True).start()


def _serve(req):
    import time as _time
    t0 = _time.time()
    if req.get("op") == "prefetch":
        # Warm the cache for a request the app expects next (the next page,
        # the default tab at startup). No reply — the real request, when it
        # comes, is a cache hit or joins this fetch in flight.
        try:
            handle_cached(req.get("req") or {})
        except Exception:
            pass
        return
    try:
        reply = handle_cached(req)
    except NotSignedIn as e:
        # which case it is, so the app offers the right way out
        reply = {"ok": False, "error": str(e), "auth": e.kind}
    except Exception as e:  # yt-dlp raises rich exception types; flatten
        msg = str(e).replace("\n", " ")[:300]
        reply = {"ok": False, "error": msg}
        if "401" in msg or "Unauthorized" in msg:
            # Stale/logged-out browser cookies read fine but YouTube
            # rejects them — only a fresh browser login fixes it.
            b = _browser_word()
            reply.update(auth="expired", error=(
                f"{b}'s YouTube sign-in has run out — open youtube.com in {b} "
                "(that signs it back in), then press F5"))
    reply["id"] = req.get("id")
    reply["ms"] = int((_time.time() - t0) * 1000)
    send(reply)
    if reply.get("ok") and reply.get("entries"):
        _resolve_channels_later(reply["entries"])


def main():
    # Requests run CONCURRENTLY. The worker used to answer one at a time, so a
    # slow For You page held up the search typed after it, and the history
    # ping queued behind both. Replies carry their request id; the app already
    # drops ones it no longer wants.
    from concurrent.futures import ThreadPoolExecutor
    pool = ThreadPoolExecutor(max_workers=6)
    # Settle the mode once, in config: until now it was inferred from the
    # login copy under ~/.cache, and a cleared cache would have quietly
    # dropped a signed-in machine onto codec's own lists.
    if yt_config().get("mode") not in ("account", "local"):
        try:
            save_youtube(mode=mode())
        except OSError:
            pass
    send({"event": "ready", "cookies": bool(cookies_spec())})
    # who YouTube is here, as soon as it's known (a network round trip)
    pool.submit(announce_account)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        pool.submit(_serve, req)


if __name__ == "__main__":
    if "--cookie-spec" in sys.argv:
        # The login in use as a yt-dlp --cookies-from-browser value
        # (BROWSER[+KEYRING][:PROFILE]); empty for codec's own lists.
        print(login_spec())
        sys.exit(0)
    if "--chat" in sys.argv:
        at = sys.argv.index("--chat")
        if at + 1 >= len(sys.argv):
            send({"event": "error", "error": "--chat needs a url"})
            sys.exit(2)
        chat_main(sys.argv[at + 1])
        sys.exit(0)
    if "--auth" in sys.argv:
        oauth_authorize()
        sys.exit(0)
    if "--chat-send" in sys.argv:
        at = sys.argv.index("--chat-send")
        if at + 2 >= len(sys.argv):
            send({"ok": False, "error": "--chat-send needs <url> <message>"})
            sys.exit(2)
        try:
            chat_send(sys.argv[at + 1], sys.argv[at + 2])
            send({"ok": True})
        except Exception as e:
            send({"ok": False, "error": str(e).replace("\n", " ")[:200]})
        sys.exit(0)
    if "--watch" in sys.argv:
        at = sys.argv.index("--watch")
        if at + 1 >= len(sys.argv):
            send({"ok": False, "error": "--watch needs <url> [pos]"})
            sys.exit(2)
        pos = sys.argv[at + 2] if at + 2 < len(sys.argv) else "0"
        try:
            register_watch(sys.argv[at + 1], float(pos))
            send({"ok": True})
        except Exception as e:
            send({"ok": False, "error": str(e).replace("\n", " ")[:200]})
        sys.exit(0)
    main()
