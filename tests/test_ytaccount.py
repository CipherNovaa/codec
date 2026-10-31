#!/usr/bin/env python3
"""The YouTube login finder (codec_ytaccount.py), offline.

A made-up home with a Zen profile signed into YouTube (its newest cookie
still only in the -wal file, as a running browser leaves it), a Firefox
profile that isn't, and a Chromium profile whose cookie NAMES say it is —
found, labelled, picked and read without touching the network.

    python3 tests/test_ytaccount.py
"""
import os, pathlib, sqlite3, sys, tempfile, time

HOME = pathlib.Path(tempfile.mkdtemp(prefix="ytaccount-"))
os.environ["HOME"] = str(HOME)
os.environ["XDG_CONFIG_HOME"] = str(HOME / ".config")
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "scripts"))
import codec_ytaccount as a

fails = 0


def check(name, got, want):
    global fails
    ok = got == want
    fails += 0 if ok else 1
    print(f"  {'ok ' if ok else 'FAIL'} {name}: {got!r}" + ("" if ok else f" (want {want!r})"))


FF_SCHEMA = ("CREATE TABLE moz_cookies (id INTEGER PRIMARY KEY, originAttributes TEXT "
             "NOT NULL DEFAULT '', name TEXT, value TEXT, host TEXT, path TEXT, expiry "
             "INTEGER, lastAccessed INTEGER, creationTime INTEGER, isSecure INTEGER, "
             "isHttpOnly INTEGER)")


def firefox_profile(folder, cookies, version=16, wal_cookies=()):
    """A cookies.sqlite; `wal_cookies` are written last and left in the -wal
    (the connection is returned open, as a running browser holds it)."""
    folder.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(folder / "cookies.sqlite")
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA wal_autocheckpoint=0")
    con.execute(FF_SCHEMA)
    con.execute(f"PRAGMA user_version={version}")
    far = int((time.time() + 86400 * 365) * (1000 if version >= 16 else 1))
    for host, name, value in cookies:
        con.execute("INSERT INTO moz_cookies (name, value, host, path, expiry, isSecure) "
                    "VALUES (?, ?, ?, '/', ?, 1)", (name, value, host, far))
    con.commit()
    con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    for host, name, value in wal_cookies:
        con.execute("INSERT INTO moz_cookies (name, value, host, path, expiry, isSecure) "
                    "VALUES (?, ?, ?, '/', ?, 1)", (name, value, host, far))
    con.commit()
    return con


# ── Zen: signed in; the login's newest half only in the -wal ─────────────────
zen = HOME / ".zen"
zen.mkdir()
(zen / "profiles.ini").write_text(
    "[Profile0]\nName=Default (release)\nIsRelative=1\nPath=abcd.Default (release)\n\n"
    "[Profile1]\nName=Old\nIsRelative=1\nPath=efgh.Old\nDefault=1\n\n"
    "[Install123]\nDefault=abcd.Default (release)\nLocked=1\n")
held = firefox_profile(zen / "abcd.Default (release)",
                       [(".youtube.com", "SAPISID", "zen-sapisid"),
                        (".youtube.com", "PREF", "f6=40000000"),
                        (".bank.example", "session", "do-not-take")],
                       wal_cookies=[(".youtube.com", "__Secure-3PSIDTS", "rotated-just-now")])
old = firefox_profile(zen / "efgh.Old", [(".example.org", "x", "y")])
old.close()

# ── Firefox (XDG folder, FF147+): a profile not signed in ───────────────────
ff = HOME / ".config/mozilla/firefox"
firefox_profile(ff / "x1.default-release", [(".youtube.com", "PREF", "f6=1")]).close()

# ── Chromium: signed in by its cookie names (values stay encrypted) ─────────
cr = HOME / ".config/chromium"
(cr / "Default").mkdir(parents=True)
(cr / "Local State").write_text('{"profile": {"info_cache": {"Default": {"name": "Work"}},'
                                ' "last_used": "Default"}}')
con = sqlite3.connect(cr / "Default/Cookies")
con.execute("CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, "
            "encrypted_value BLOB, expires_utc INTEGER, path TEXT)")
con.execute("INSERT INTO cookies VALUES ('.youtube.com', 'SAPISID', '', X'763130', ?, '/')",
            (int((time.time() + 11644473600 + 86400) * 1e6),))
con.commit()
con.close()

print("finding")
found = a.find_profiles()
by = {(p["label"], p["profileName"]): p for p in found}
check("all four profiles found", sorted(by), sorted([("ZEN", "Default (release)"), ("ZEN", "Old"),
                                                    ("FIREFOX", "default-release"),
                                                    ("CHROMIUM", "Work")]))
check("zen signed in", by[("ZEN", "Default (release)")]["signedIn"], True)
check("zen's install default wins over Default=1", by[("ZEN", "Default (release)")]["isDefault"], True)
check("old zen profile not signed in", by[("ZEN", "Old")]["signedIn"], False)
check("firefox not signed in", by[("FIREFOX", "default-release")]["signedIn"], False)
check("chromium signed in (names only)", by[("CHROMIUM", "Work")]["signedIn"], True)
best = a.best_profile(found)
check("best = the signed-in Zen default", (best["label"], best["profileName"]), ("ZEN", "Default (release)"))

print("reading a login")
jar, used = a.load_cookies(best["spec"])
names = {c.name: c.value for c in jar}
check("the -wal's newest cookie is read", names.get("__Secure-3PSIDTS"), "rotated-just-now")
check("other sites' cookies are not kept", "session" in names, False)
check("spec unchanged for firefox", used, best["spec"])
check("auth cookie dict", sorted(a.yt_cookie_dict(jar)), ["PREF", "SAPISID", "__Secure-3PSIDTS"])
held.close()

print("specs")
check("parse full", a.parse_spec("chromium+kwallet6:/x/Default::none"),
      ("chromium", "/x/Default", "KWALLET6", "none"))
check("parse bare", a.parse_spec("firefox"), ("firefox", None, None, None))
check("parse empty", a.parse_spec(""), None)
check("make", a.make_spec("brave", "/p", "GNOMEKEYRING"), "brave+gnomekeyring:/p")
check("label: zen by its folder", a.label_of(best["spec"]), "ZEN")
check("label: zen elsewhere, by name", a.label_of("firefox:/mnt/old-home/.zen/q.default"), "ZEN")
check("label: chrome family", a.label_of("chromium:" + str(cr / "Default")), "CHROMIUM")
check("label: plain firefox", a.label_of("firefox"), "FIREFOX")
check("identity needs a login", a.identity({}), None)

print("the channel a login acts as")
import urllib.request
sent = []
SW = {   # YouTube's sw.js_data, cut down: a login acting as a brand channel, and one not
    "brand": b')]}\'\n\n[["yt.sw.adr",null,[[["en-GB","CA",null,"1.2.3.4",null,null,null,null,null,'
             b'null,null,"","",null,null,1,"2.20261016.01.00"]],null,null,0,null,null,null,'
             b'"111111111111111111111",null,null,null,"222222222222222222222"],'
             b'"111111111111111111111||222222222222222222222"]]',
    "plain": b')]}\'\n\n[["yt.sw.adr",null,[[["en-GB","CA",null,"1.2.3.4",null,null,null,null,null,'
             b'null,null,"","",null,null,1,"2.20261016.01.00"]],null,null,0],"222222222222222222222||"]]',
}


class _Reply:
    def __init__(self, body):
        self.body = body

    def read(self):
        return self.body


def fake_open(req, timeout=0):
    sent.append(req)
    if req.full_url.endswith("sw.js_data"):
        return _Reply(SW[fake_open.which])
    return _Reply(b"{}")


real_open, urllib.request.urlopen = urllib.request.urlopen, fake_open
ck = {"SAPISID": "s", "SID": "x"}
fake_open.which = "brand"
sess = a.session(ck)
check("a brand channel's page id", sess, {"page": "111111111111111111111", "version": "2.20261016.01.00"})
a.innertube("subscription/subscribe", {"channelIds": ["UCx"]}, ck, sess=sess)
h = {k.lower(): v for k, v in sent[-1].header_items()}
check("a write acts as the channel", (h.get("x-goog-pageid"), h.get("x-goog-authuser")),
      ("111111111111111111111", "0"))
fake_open.which = "plain"
check("a plain account has no page", a.session(ck), {"version": "2.20261016.01.00"})
a.innertube("player", {"videoId": "v"})
h = {k.lower(): v for k, v in sent[-1].header_items()}
check("anonymous carries no login", ("authorization" in h, "x-goog-pageid" in h), (False, False))
urllib.request.urlopen = real_open

print("FAIL" if fails else "all ok")
sys.exit(1 if fails else 0)
