#!/usr/bin/env python3
"""codec_ytaccount — the YouTube login codec borrows from a browser.

codec signs into YouTube the way yt-dlp does: with the cookies of a browser
that is already signed in on this machine (Google offers a player like codec
no other way in — docs/YOUTUBE.md). This module is everything about that:

  find_profiles()   every browser profile on this machine, and whether it is
                    signed into YouTube (read from the cookie database's
                    names alone — nothing is decrypted to look)
  load_cookies()    the YouTube and Google cookies of one profile, as a jar
  session()         the channel that login acts as (a brand account's page
                    id, which every signed call must carry)
  identity()        who that login is: name, handle, picture

A login is named by a yt-dlp browser spec, BROWSER[+KEYRING][:PROFILE], with
PROFILE a path — "firefox:/home/me/.zen/abcd.Default (release)". That one
string is what config youtube.cookiesFromBrowser holds and what mpv and the
hub's yt-dlp are handed, so every part of codec reads the same login.

    python3 codec_ytaccount.py          # the profiles found here, as JSON
"""
import configparser
import http.cookiejar
import json
import os
import shutil
import sqlite3
import tempfile
import time
from pathlib import Path

HOME = Path.home()
XDG_CONFIG = Path(os.environ.get("XDG_CONFIG_HOME") or HOME / ".config")
_FLAT = HOME / ".var/app"     # Flatpak apps keep their home here

# Firefox and its forks share one cookie database format. yt-dlp knows only
# Firefox's own folders; the forks are found here and handed over by path.
FIREFOX_FAMILY = [
    ("zen", "ZEN", [HOME / ".zen", XDG_CONFIG / "zen",
                    _FLAT / "app.zen_browser.zen/.zen",
                    _FLAT / "app.zen_browser.zen/config/zen"]),
    ("firefox", "FIREFOX", [XDG_CONFIG / "mozilla/firefox", HOME / ".mozilla/firefox",
                            _FLAT / "org.mozilla.firefox/config/mozilla/firefox",
                            _FLAT / "org.mozilla.firefox/.mozilla/firefox",
                            HOME / "snap/firefox/common/.mozilla/firefox"]),
    ("librewolf", "LIBREWOLF", [HOME / ".librewolf", XDG_CONFIG / "librewolf/librewolf",
                                _FLAT / "io.gitlab.librewolf-community/.librewolf",
                                _FLAT / "io.gitlab.librewolf-community/config/librewolf/librewolf"]),
    ("floorp", "FLOORP", [HOME / ".floorp", _FLAT / "one.ablaze.floorp/.floorp"]),
    ("waterfox", "WATERFOX", [HOME / ".waterfox", _FLAT / "net.waterfox.waterfox/.waterfox"]),
]
# Chrome and its relatives: (yt-dlp's name, label, the browser's folders)
CHROMIUM_FAMILY = [
    ("chrome", "CHROME", [XDG_CONFIG / "google-chrome",
                          _FLAT / "com.google.Chrome/config/google-chrome"]),
    ("chromium", "CHROMIUM", [XDG_CONFIG / "chromium",
                              _FLAT / "org.chromium.Chromium/config/chromium",
                              HOME / "snap/chromium/common/chromium"]),
    ("brave", "BRAVE", [XDG_CONFIG / "BraveSoftware/Brave-Browser",
                        _FLAT / "com.brave.Browser/config/BraveSoftware/Brave-Browser"]),
    ("vivaldi", "VIVALDI", [XDG_CONFIG / "vivaldi", _FLAT / "com.vivaldi.Vivaldi/config/vivaldi"]),
    ("edge", "EDGE", [XDG_CONFIG / "microsoft-edge",
                      _FLAT / "com.microsoft.Edge/config/microsoft-edge"]),
    ("opera", "OPERA", [XDG_CONFIG / "opera", _FLAT / "com.opera.Opera/config/opera"]),
]
_CHROMIUM_NAMES = {b for b, _, _ in CHROMIUM_FAMILY} | {"whale"}

# The cookies that say "signed in": YouTube's API key pair. LOGIN_INFO alone
# outlives a sign-out, so it doesn't count.
_LOGIN = ("SAPISID", "__Secure-3PAPISID")
# Only these sites' cookies are kept — codec has no business holding the
# browser's logins to anything else (the old copy held all ~1000 of them).
_KEEP_DOMAINS = ("youtube.com", "google.com")


# ── specs ──────────────────────────────────────────────────────────────────
def parse_spec(spec):
    """yt-dlp's BROWSER[+KEYRING][:PROFILE][::CONTAINER] → (browser, profile,
    keyring, container); None for an empty spec."""
    spec = (spec or "").strip()
    if not spec:
        return None
    container = None
    if "::" in spec:
        spec, container = spec.split("::", 1)
    head, _, profile = spec.partition(":")
    browser, _, keyring = head.partition("+")
    return (browser.lower(), profile or None, (keyring or None) and keyring.upper(),
            container or None)


def make_spec(browser, profile=None, keyring=None):
    head = browser + (f"+{keyring.lower()}" if keyring else "")
    return head + (f":{profile}" if profile else "")


def _family_of(path):
    """The (id, label) of the browser a profile folder belongs to, by where it
    lives — so a Zen profile reads ZEN although yt-dlp calls it "firefox"."""
    try:
        real = Path(path).resolve()
    except OSError:
        return None
    for fam, label, roots in FIREFOX_FAMILY + [(b, l, r) for b, l, r in CHROMIUM_FAMILY]:
        for root in roots:
            try:
                if real == root.resolve() or root.resolve() in real.parents:
                    return fam, label
            except OSError:
                continue
    return None


def label_of(spec):
    """What to call a spec's browser on screen: ZEN, FIREFOX, CHROME…"""
    p = parse_spec(spec)
    if not p:
        return ""
    browser, profile = p[0], p[1]
    if profile and ("/" in profile):
        fam = _family_of(profile)
        if fam:
            return fam[1]
        # not under this home's folders (another HOME, a moved profile): the
        # browser's own folder name still says which it is
        low = profile.lower()
        for hint, label in (("/.zen/", "ZEN"), ("zen_browser", "ZEN"), ("librewolf", "LIBREWOLF"),
                            ("floorp", "FLOORP"), ("waterfox", "WATERFOX"),
                            ("bravesoftware", "BRAVE"), ("vivaldi", "VIVALDI"),
                            ("microsoft-edge", "EDGE"), ("google-chrome", "CHROME")):
            if hint in low:
                return label
    for fam, label, _ in FIREFOX_FAMILY:
        if fam == browser:
            return label
    for b, label, _ in CHROMIUM_FAMILY:
        if b == browser:
            return label
    return browser.upper()


# ── finding profiles ───────────────────────────────────────────────────────
def _firefox_profiles(root):
    """[(folder, name, is_default)] under a Firefox-family root: the profiles
    its profiles.ini lists, else any folder holding a cookie database."""
    out = []
    ini = root / "profiles.ini"
    if ini.is_file():
        cp = configparser.RawConfigParser()
        try:
            cp.read(ini, encoding="utf-8")
        except (configparser.Error, UnicodeDecodeError):
            cp = None
        if cp is not None:
            defaults = {cp.get(s, "Default", fallback="") for s in cp.sections()
                        if s.startswith("Install")}
            for s in cp.sections():
                if not s.startswith("Profile") or not cp.has_option(s, "Path"):
                    continue
                rel = cp.get(s, "Path")
                d = (root / rel) if cp.get(s, "IsRelative", fallback="1") == "1" else Path(rel)
                is_def = rel in defaults or (not defaults and cp.get(s, "Default", fallback="") == "1")
                out.append((d, cp.get(s, "Name", fallback=d.name), is_def))
    if not out:
        for db in sorted(list(root.glob("*/cookies.sqlite")) + list(root.glob("Profiles/*/cookies.sqlite"))):
            # a profile folder is "<random>.<name>": show the name
            n = db.parent.name
            out.append((db.parent, n.split(".", 1)[1] if "." in n else n, False))
    return [(d, n, df) for d, n, df in out if (d / "cookies.sqlite").is_file()]


def _chromium_profiles(root):
    """[(folder, name, is_default)] of a Chromium-family browser: Local State
    names its profiles ("Person 1", "Work"); Opera keeps one, at the root."""
    names = {}
    try:
        st = json.loads((root / "Local State").read_text())
        cache = (st.get("profile") or {}).get("info_cache") or {}
        names = {k: (v or {}).get("name") or k for k, v in cache.items()}
        last = (st.get("profile") or {}).get("last_used") or "Default"
    except (OSError, ValueError):
        last = "Default"
    out = []
    dirs = set(names) | {p.name for p in root.iterdir() if p.is_dir()
                         and (p.name == "Default" or p.name.startswith("Profile "))}
    for d in sorted(dirs):
        folder = root / d
        if _chromium_db(folder):
            out.append((folder, names.get(d, d), d == last))
    if not out and _chromium_db(root):
        out.append((root, "Default", True))
    return out


def _chromium_db(folder):
    for rel in ("Network/Cookies", "Cookies"):
        p = folder / rel
        if p.is_file():
            return p
    return None


def _copy_db(db, tmpdir):
    """A private copy of a live cookie database to read from. Firefox keeps
    its newest writes in the -wal file beside it (yt-dlp copies only the main
    file, so a cookie YouTube just rotated could read stale); copied together,
    sqlite replays them."""
    dst = Path(tmpdir) / db.name
    shutil.copyfile(db, dst)
    for side in ("-wal", "-shm"):
        s = db.with_name(db.name + side)
        if s.is_file():
            shutil.copyfile(s, dst.with_name(dst.name + side))
    return dst


def _firefox_signed_in(folder):
    db = folder / "cookies.sqlite"
    with tempfile.TemporaryDirectory(prefix="codec-yt") as tmp:
        con = sqlite3.connect(_copy_db(db, tmp))
        try:
            ver = con.execute("PRAGMA user_version").fetchone()[0]
            rows = con.execute(
                "SELECT expiry FROM moz_cookies WHERE host LIKE '%youtube.com' "
                "AND name IN (?, ?) AND NOT INSTR(originAttributes, 'userContextId=')",
                _LOGIN).fetchall()
        finally:
            con.close()
    now = time.time()
    # Firefox 142 (schema 16) moved expiry to milliseconds
    return any((e / 1000 if ver >= 16 else e) > now for (e,) in rows if e)


def _chromium_signed_in(folder):
    db = _chromium_db(folder)
    if not db:
        return False
    with tempfile.TemporaryDirectory(prefix="codec-yt") as tmp:
        con = sqlite3.connect(_copy_db(db, tmp))
        try:
            rows = con.execute(
                "SELECT expires_utc FROM cookies WHERE host_key LIKE '%youtube.com' "
                "AND name IN (?, ?)", _LOGIN).fetchall()
        finally:
            con.close()
    # microseconds since 1601; 0 = a session cookie
    now_us = (time.time() + 11644473600) * 1e6
    return any(e == 0 or e > now_us for (e,) in rows)


def find_profiles():
    """Every browser profile on this machine that holds cookies, newest
    first within each browser: [{spec, browser, label, profileName, path,
    isDefault, signedIn, family}]. Looking reads cookie NAMES only."""
    found, seen = [], set()

    def add(entry, folder):
        try:
            key = str(Path(folder).resolve())
        except OSError:
            return
        if key not in seen:
            seen.add(key)
            found.append(entry)

    for fam, label, roots in FIREFOX_FAMILY:
        for root in roots:
            if not root.is_dir():
                continue
            for folder, name, is_def in _firefox_profiles(root):
                try:
                    signed = _firefox_signed_in(folder)
                except (OSError, sqlite3.Error):
                    signed = False
                add({"spec": make_spec("firefox", str(folder)), "browser": "firefox",
                     "family": fam, "label": label, "profileName": name,
                     "path": str(folder), "isDefault": is_def, "signedIn": signed,
                     "flatpak": str(_FLAT) in str(root)}, folder)
    for browser, label, roots in CHROMIUM_FAMILY:
        for root in roots:
            if not root.is_dir():
                continue
            for folder, name, is_def in _chromium_profiles(root):
                try:
                    signed = _chromium_signed_in(folder)
                except (OSError, sqlite3.Error):
                    signed = False
                add({"spec": make_spec(browser, str(folder)), "browser": browser,
                     "family": browser, "label": label, "profileName": name,
                     "path": str(folder), "isDefault": is_def, "signedIn": signed,
                     "flatpak": str(_FLAT) in str(root)}, folder)
    return found


def best_profile(profiles=None):
    """The profile codec would pick on its own: a signed-in one, the browser's
    default profile first, Firefox-family before Chrome-family (no keyring to
    unlock), then the most recently used."""
    profiles = find_profiles() if profiles is None else profiles
    signed = [p for p in profiles if p["signedIn"]]
    if not signed:
        return None
    order = [f for f, _, _ in FIREFOX_FAMILY] + [b for b, _, _ in CHROMIUM_FAMILY]

    def mtime(p):
        db = Path(p["path"]) / "cookies.sqlite"
        db = db if db.is_file() else (_chromium_db(Path(p["path"])) or db)
        try:
            return db.stat().st_mtime
        except OSError:
            return 0
    return sorted(signed, key=lambda p: (not p["isDefault"],
                                         order.index(p["family"]) if p["family"] in order else 99,
                                         -mtime(p)))[0]


# ── loading a login ────────────────────────────────────────────────────────
class _Quiet:
    """yt-dlp's logger, silenced — its progress bars and keyring notes would
    land on the worker's JSON pipe."""
    def debug(self, *a, **k): pass
    info = warning = debug
    def error(self, *a, **k): pass


def _keep(cookie):
    d = (cookie.domain or "").lstrip(".")
    return any(d == k or d.endswith("." + k) for k in _KEEP_DOMAINS)


def _firefox_jar(folder):
    """A Firefox-family profile's YouTube + Google cookies, read with its
    -wal (see _copy_db) and without containers."""
    jar = http.cookiejar.MozillaCookieJar()
    db = Path(folder) / "cookies.sqlite"
    with tempfile.TemporaryDirectory(prefix="codec-yt") as tmp:
        con = sqlite3.connect(_copy_db(db, tmp))
        try:
            ver = con.execute("PRAGMA user_version").fetchone()[0]
            rows = con.execute(
                "SELECT host, name, value, path, expiry, isSecure FROM moz_cookies "
                "WHERE (host LIKE '%youtube.com' OR host LIKE '%google.com') "
                "AND NOT INSTR(originAttributes, 'userContextId=')").fetchall()
        finally:
            con.close()
    for host, name, value, path, expiry, secure in rows:
        if expiry and ver >= 16:
            expiry = int(expiry / 1000)
        jar.set_cookie(http.cookiejar.Cookie(
            0, name, value, None, False, host, bool(host), host.startswith("."),
            path, bool(path), bool(secure), expiry or None, False, None, None, {}))
    return jar


def _has_login(jar):
    return any(c.name in _LOGIN and c.value and "youtube.com" in (c.domain or "")
               for c in jar)


def _keyrings():
    """Keyrings to try for a Chrome-family browser whose cookies didn't
    decrypt with yt-dlp's own pick (on Hyprland, sway and the like it picks
    none). The ones whose service is on this session's bus, KDE's first."""
    out = []
    try:
        import subprocess
        names = subprocess.run(
            ["busctl", "--user", "list", "--no-pager", "--no-legend"],
            capture_output=True, text=True, timeout=3).stdout
    except (OSError, ValueError):
        names = ""
    if "org.kde.kwalletd6" in names:
        out.append("KWALLET6")
    if "org.kde.kwalletd5" in names:
        out.append("KWALLET5")
    if "org.freedesktop.secrets" in names or "gnome-keyring" in names:
        try:
            import secretstorage  # noqa: F401  yt-dlp needs it for GNOME's
            out.append("GNOMEKEYRING")
        except ImportError:
            pass
    return out


def load_cookies(spec):
    """(jar, spec) — the YouTube + Google cookies of the login a spec names,
    and the spec that read them (a Chrome-family spec gains the keyring that
    unlocked it). The jar is empty when nothing could be read."""
    p = parse_spec(spec)
    jar = http.cookiejar.MozillaCookieJar()
    if not p:
        return jar, spec
    browser, profile, keyring, container = p
    if browser == "firefox" and profile and "/" in profile and not container:
        folder = Path(profile)
        if not (folder / "cookies.sqlite").is_file():   # a browser root: its newest profile
            dbs = sorted(folder.glob("*/cookies.sqlite"), key=lambda d: d.stat().st_mtime)
            folder = dbs[-1].parent if dbs else folder
        try:
            return _firefox_jar(folder), spec
        except (OSError, sqlite3.Error):
            return jar, spec
    from yt_dlp.cookies import extract_cookies_from_browser

    def read(kr):
        try:
            got = extract_cookies_from_browser(browser, profile, _Quiet(),
                                               keyring=kr, container=container)
        except Exception:
            return None
        kept = http.cookiejar.MozillaCookieJar()
        for c in got:
            if _keep(c):
                kept.set_cookie(c)
        return kept

    first = read(keyring)
    if first is not None and _has_login(first):
        return first, spec
    # A Chrome-family login that is THERE (its cookie names say so) but didn't
    # decrypt: yt-dlp guessed the wrong keyring. Asking another can open its
    # unlock prompt, so only then, and only the ones running.
    if (browser in _CHROMIUM_NAMES and not keyring and profile and "/" in profile
            and _chromium_signed_in(Path(profile))):
        for kr in _keyrings():
            got = read(kr)
            if got is not None and _has_login(got):
                return got, make_spec(browser, profile, kr)
    return (first if first is not None else jar), spec


# Only the cookies YouTube authenticates with: the whole youtube.com set in
# one Cookie header passes YouTube's limit (HTTP 413).
AUTH_COOKIES = {
    "SID", "HSID", "SSID", "APISID", "SAPISID", "LOGIN_INFO", "PREF",
    "VISITOR_INFO1_LIVE", "YSC", "__Secure-1PSID", "__Secure-3PSID",
    "__Secure-1PAPISID", "__Secure-3PAPISID", "__Secure-1PSIDTS",
    "__Secure-3PSIDTS", "SIDCC", "__Secure-1PSIDCC", "__Secure-3PSIDCC",
}


def yt_cookie_dict(jar):
    """{name: value} of the youtube.com cookies YouTube authenticates with."""
    return {c.name: c.value for c in jar
            if "youtube.com" in (c.domain or "") and c.value and c.name in AUTH_COOKIES}


# ── who it is ──────────────────────────────────────────────────────────────
CLIENT_VERSION = "2.20261016.01.00"     # youtube.com's web client, when unread


def session(cookies):
    """{page, version} of the login, as youtube.com's own page holds them.

    A login can act as a channel of its own (a brand account): the browser
    then sends that channel's id as X-Goog-PageId, and a call without it acts
    as the plain Google account — a subscribe or a new playlist lands there,
    where the channel's lists never show it. Read from YouTube's
    service-worker config (3 KB, ~0.1 s): its data-sync id is
    "<page>||<user>" when a channel is in use, "<user>||" when not."""
    import re
    import urllib.request
    if not cookies:
        return {}
    req = urllib.request.Request("https://www.youtube.com/sw.js_data", headers={
        "Cookie": "; ".join(f"{k}={v}" for k, v in cookies.items()),
        "User-Agent": "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"})
    raw = urllib.request.urlopen(req, timeout=10).read().decode("utf-8", "replace")
    out = {}
    m = re.search(r'"(\d+)\|\|(\d+)"', raw)
    if m:
        out["page"] = m.group(1)
    m = re.search(r'"(2\.\d{8}\.\d{2}\.\d{2})"', raw)
    if m:
        out["version"] = m.group(1)
    return out


def innertube(endpoint, body, cookies=None, timeout=15, sess=None):
    """One InnerTube call, as youtube.com's web page makes it: signed with
    SAPISIDHASH when cookies are given (acting as the login's channel when
    `sess` names one — session()), anonymous otherwise."""
    import hashlib
    import urllib.request
    sess = sess or {}
    version = sess.get("version") or CLIENT_VERSION
    headers = {"Origin": "https://www.youtube.com",
               "X-Origin": "https://www.youtube.com",
               "Content-Type": "application/json",
               "X-Youtube-Client-Name": "1",
               "X-Youtube-Client-Version": version}
    sapisid = (cookies or {}).get("SAPISID") or (cookies or {}).get("__Secure-3PAPISID")
    if sapisid:
        ts = int(time.time())
        digest = hashlib.sha1(f"{ts} {sapisid} https://www.youtube.com".encode()).hexdigest()
        headers["Authorization"] = f"SAPISIDHASH {ts}_{digest}"
        headers["Cookie"] = "; ".join(f"{k}={v}" for k, v in cookies.items())
        # the page id counts only beside the session it belongs to (the
        # browser's first Google login, as yt-dlp's page read also takes)
        headers["X-Goog-AuthUser"] = "0"
        if sess.get("page"):
            headers["X-Goog-PageId"] = sess["page"]
    body = dict(body)
    body["context"] = {"client": {"clientName": "WEB", "clientVersion": version}}
    req = urllib.request.Request("https://www.youtube.com/youtubei/v1/" + endpoint,
                                 json.dumps(body).encode(), headers)
    return json.loads(urllib.request.urlopen(req, timeout=timeout).read())


def _find(o, key):
    if isinstance(o, dict):
        if key in o:
            return o[key]
        for v in o.values():
            r = _find(v, key)
            if r is not None:
                return r
    elif isinstance(o, list):
        for v in o:
            r = _find(v, key)
            if r is not None:
                return r
    return None


def _text(t):
    if not isinstance(t, dict):
        return ""
    return t.get("simpleText") or "".join(r.get("text", "") for r in t.get("runs") or [])


def identity(cookies, sess=None):
    """{name, handle, photo} of the account a cookie set signs in as — the
    channel it acts as, when it has one — or None when YouTube says those
    cookies aren't signed in (a login that ran out)."""
    if not cookies or not (cookies.get("SAPISID") or cookies.get("__Secure-3PAPISID")):
        return None
    if sess is None:
        try:
            sess = session(cookies)
        except Exception:
            sess = {}
    d = innertube("account/account_menu", {}, cookies, sess=sess)
    h = _find(d, "activeAccountHeaderRenderer")
    if not h:
        return None
    photos = (h.get("accountPhoto") or {}).get("thumbnails") or []
    photo = photos[-1]["url"] if photos else ""
    if photo.startswith("//"):
        photo = "https:" + photo
    return {"name": _text(h.get("accountName")), "handle": _text(h.get("channelHandle")),
            "photo": photo}


if __name__ == "__main__":
    print(json.dumps(find_profiles(), indent=2))
