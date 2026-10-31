#!/usr/bin/env python3
"""Paired devices — who may use this hub's private port (:8200).

codec-serve used to answer anyone on the network: every file under its root,
every control. That's fine in a house that trusts its Wi-Fi and wrong on
anyone else's. So a hub keeps a list of devices it has said yes to, and
answers only those — plus itself (loopback), a TV while something is being
cast to it, and party guests (whose links carry the party's own key).

  joining      a device asks (POST /pair/request), the hub's screen shows
               "<NAME> WANTS TO JOIN · ⏎ ALLOW" (the app polls /pair/pending
               and answers /pair/answer), the device collects its key
               (GET /pair/wait) — once; the hub keeps only its SHA-256.
  using it     the key rides every request: X-Codec-Key (the app, scripts),
               a codec_key cookie (a phone's browser), or ?dk= (a player that
               can only take a URL).
  a TV         can't carry a key on a video request, so whoever casts tells
               the hub "allow this TV" (POST /pair/tv) and its address may
               fetch media and send its remote's keys while the cast lasts.
  trusted      settings.lanOpen = true: every device on the network is let in
               without joining — how codec always worked. The author's house runs
               this way until its laptop, phone and TV have keys; a new
               install starts paired-only.

The device list lives in the data folder (paired.json, owner-only).
"""
import hashlib
import json
import os
import secrets
import threading
import time
from pathlib import Path

import codec_paths

PAIR_FILE = codec_paths.DATA / "paired.json"
CFG = Path.home() / ".config/codec/config.json"

REQUEST_TTL = 120          # an unanswered request expires (s)
MAX_PENDING = 5            # a flood of requests can't bury a real one
TV_HOURS = 8               # a cast's allowance (a long film, a pause, a rewatch)

_LOCK = threading.Condition()
_DEVICES = []              # [{id, name, kind, keyHash, added, seen}]
_PENDING = {}              # rid -> {id, name, kind, ip, at, state, key}
_TVS = {}                  # ip -> expires
_CFG_CACHE = {"at": 0.0, "lanOpen": False}


def _load():
    global _DEVICES
    try:
        _DEVICES = json.loads(PAIR_FILE.read_text()).get("devices") or []
    except (OSError, ValueError):
        _DEVICES = []


def _save():
    try:
        PAIR_FILE.parent.mkdir(parents=True, exist_ok=True)
        tmp = PAIR_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps({"devices": _DEVICES}, indent=1))
        os.chmod(tmp, 0o600)
        tmp.replace(PAIR_FILE)
    except OSError:
        pass


_load()


def _hash(key):
    return hashlib.sha256(str(key).encode()).hexdigest()


def lan_open():
    """settings.lanOpen — re-read every few seconds, so the Settings switch
    takes effect without a restart."""
    now = time.time()
    if now - _CFG_CACHE["at"] > 5:
        try:
            s = json.loads(CFG.read_text()).get("settings", {})
            _CFG_CACHE["lanOpen"] = s.get("lanOpen") is True
        except (OSError, ValueError):
            _CFG_CACHE["lanOpen"] = False
        _CFG_CACHE["at"] = now
    return _CFG_CACHE["lanOpen"]


def key_ok(key):
    """The paired device this key belongs to, or None."""
    if not key:
        return None
    h = _hash(key)
    with _LOCK:
        for d in _DEVICES:
            if secrets.compare_digest(d.get("keyHash", ""), h):
                if time.time() - float(d.get("seen") or 0) > 3600:
                    d["seen"] = time.time()
                    _save()
                return dict(d)
    return None


def _expire():
    now = time.time()
    for rid in [r for r, p in _PENDING.items()
                if now - p["at"] > REQUEST_TTL and p["state"] == "pending"]:
        _PENDING[rid]["state"] = "expired"
    for rid in [r for r, p in _PENDING.items() if now - p["at"] > REQUEST_TTL * 3]:
        del _PENDING[rid]


def request(dev_id, name, kind, ip):
    """A device asks to join. Returns the request id, or "" when too many are
    already waiting. The same device asking again replaces its old request."""
    dev_id = str(dev_id or "")[:64] or ("anon-" + secrets.token_hex(4))
    name = (str(name or "") or dev_id)[:40]
    kind = str(kind or "device")[:16]
    with _LOCK:
        _expire()
        for rid in [r for r, p in _PENDING.items() if p["id"] == dev_id]:
            del _PENDING[rid]
        if sum(1 for p in _PENDING.values() if p["state"] == "pending") >= MAX_PENDING:
            return ""
        rid = secrets.token_urlsafe(12)
        _PENDING[rid] = {"id": dev_id, "name": name, "kind": kind, "ip": ip,
                         "at": time.time(), "state": "pending", "key": ""}
        _LOCK.notify_all()
        return rid


def wait(rid, timeout=25.0):
    """Long-poll a request: {"state": pending|allowed|denied|expired|unknown,
    "key"?}. The key is handed over ONCE, then forgotten here."""
    end = time.time() + max(0.0, min(timeout, 30.0))
    with _LOCK:
        while True:
            _expire()
            p = _PENDING.get(rid)
            if not p:
                return {"state": "unknown"}
            if p["state"] != "pending" or time.time() >= end:
                out = {"state": p["state"]}
                if p["state"] == "allowed" and p["key"]:
                    out["key"] = p["key"]
                    p["key"] = ""
                    out["hub"] = hub_name()
                return out
            _LOCK.wait(timeout=max(0.1, end - time.time()))


def pending():
    with _LOCK:
        _expire()
        return [{"rid": r, "id": p["id"], "name": p["name"], "kind": p["kind"],
                 "ip": p["ip"], "age": int(time.time() - p["at"])}
                for r, p in _PENDING.items() if p["state"] == "pending"]


def answer(rid, allow):
    with _LOCK:
        p = _PENDING.get(rid)
        if not p or p["state"] != "pending":
            return False
        if allow:
            key = secrets.token_urlsafe(24)
            global _DEVICES
            _DEVICES = [d for d in _DEVICES if d.get("id") != p["id"]]
            _DEVICES.append({"id": p["id"], "name": p["name"], "kind": p["kind"],
                             "keyHash": _hash(key), "added": time.time(),
                             "seen": time.time()})
            _save()
            p["key"] = key
            p["state"] = "allowed"
        else:
            p["state"] = "denied"
        _LOCK.notify_all()
        return True


def devices():
    with _LOCK:
        return [{k: d.get(k) for k in ("id", "name", "kind", "added", "seen")}
                for d in _DEVICES]


def remove(dev_id):
    global _DEVICES
    with _LOCK:
        before = len(_DEVICES)
        _DEVICES = [d for d in _DEVICES if d.get("id") != dev_id]
        if len(_DEVICES) != before:
            _save()
            return True
    return False


def allow_tv(ip, hours=TV_HOURS):
    if not ip:
        return
    with _LOCK:
        _TVS[str(ip)] = time.time() + hours * 3600


def tv_ok(ip):
    with _LOCK:
        exp = _TVS.get(str(ip))
        if exp and exp < time.time():
            del _TVS[str(ip)]
            return False
        return bool(exp)


def hub_name():
    """What a joining device calls this hub: settings.hubName, else the
    machine's name."""
    try:
        n = json.loads(CFG.read_text()).get("settings", {}).get("hubName")
        if n:
            return str(n)[:40]
    except (OSError, ValueError):
        pass
    import socket
    return socket.gethostname()


# What a browser gets from a paired-only hub before it has joined: ask, then
# ALLOW on the hub's screen; /pair/wait sets the key as an HttpOnly cookie and
# the page reloads into what was asked for. It wears the app's boot pages (the
# CODEC wordmark, the steel palette, the family-6 plates of CHOOSE MEDIA
# PATHS), and carries its fonts and plate art inside itself — a device that
# hasn't joined can't fetch anything else. codec_serve.py fills %FONTS%,
# %BTN% / %BTNHOT% (btn-6 idle / hover) and %HUB%.
JOIN_PAGE = """<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>CODEC · JOIN</title><style>%FONTS%
:root{--bg:#0d1119;--fg:#e7ecf3;--acc:#a6b1c7;--dim:#9499a0;--warn:#d9694a}
*{box-sizing:border-box}
html,body{margin:0;background:var(--bg);color:var(--fg)}
body{min-height:100vh;display:flex;align-items:center;justify-content:center;
 background:linear-gradient(180deg,rgba(231,236,243,.07),transparent 42%) var(--bg)}
body:before{content:"";position:fixed;left:0;right:0;top:0;height:2px;
 background:linear-gradient(90deg,transparent,rgba(166,177,199,.5),transparent)}
main{width:100%;max-width:560px;padding:24px 16px}
.mark{margin:0;font:400 40px/1 mgscodec;letter-spacing:.42em;color:var(--fg)}
.rule{width:180px;height:2px;background:var(--acc);margin:12px 0 10px}
.sys{font:16px/1 mgshud;letter-spacing:.36em;color:var(--dim)}
h2{margin:34px 0 10px;font:400 13px/1 mgscodec;letter-spacing:.3em;color:var(--acc)}
p{margin:0 0 24px;font:16px/1.45 mgshud;letter-spacing:.06em;color:var(--dim)}
p b{font-weight:400;color:var(--fg)}
.plate{display:flex;align-items:flex-start;gap:14px;width:calc(100% + 16px);margin:0 -8px;
 padding:5px 4px 9px;
 border-style:solid;border-width:8px 12px 10px 12px;
 border-image:url(%BTN%) 4 6 5 6 fill / 8px 12px 10px 12px / 0 stretch;
 image-rendering:pixelated;background:none;color:var(--dim);text-align:left;cursor:pointer}
.plate:hover,.plate:focus-visible,.plate.lit{border-image-source:url(%BTNHOT%);color:var(--fg);outline:none}
.plate:disabled{cursor:default;opacity:.6}
.g{width:20px;text-align:center;font:32px/26px mgshud;color:var(--acc)}
.l{font:32px/26px mgshud;letter-spacing:.06em}
.s{margin-top:2px;font:16px/16px mgshud;letter-spacing:.04em;color:var(--dim)}
#st{margin-top:18px;min-height:1.4em;font:16px/1.4 mgshud;letter-spacing:.08em;color:var(--acc)}
#st.bad{color:var(--warn)}
</style></head><body><main>
<h1 class="mark">CODEC</h1><div class="rule"></div><div class="sys">MEDIA SYSTEM</div>
<h2>JOIN THIS HUB</h2>
<p>This hub only answers devices it knows. Ask to join, then press ALLOW on its screen &mdash; <b>%HUB%</b>.</p>
<button class="plate lit" id="go"><span class="g">+</span>
 <span><div class="l">ASK TO JOIN</div><div class="s">the request shows up on the hub</div></span></button>
<div id="st"></div></main>
<script>
const st=document.getElementById('st'),go=document.getElementById('go');
function say(t,bad){st.textContent=t;st.className=bad?'bad':''}
let id=localStorage.getItem('codecDevice');
if(!id){id='web-'+Math.random().toString(36).slice(2,10);localStorage.setItem('codecDevice',id)}
const ua=navigator.userAgent;
const name=/iPhone/.test(ua)?'iPhone':/iPad/.test(ua)?'iPad':/Android/.test(ua)?'Android phone':'Browser';
const kind=/iPhone|Android/.test(ua)?'phone':'browser';
go.onclick=async()=>{
  go.disabled=true;say('ASKING...');
  try{
    const r=await fetch('/pair/request',{method:'POST',headers:{'Content-Type':'application/json'},
                         body:JSON.stringify({id:id,name:name,kind:kind})});
    const j=await r.json();
    if(!j.request){say('THE HUB IS BUSY - TRY AGAIN',1);go.disabled=false;return}
    say('NOW PRESS ALLOW ON THE HUB');
    for(;;){
      const w=await(await fetch('/pair/wait?r='+encodeURIComponent(j.request)+'&t=25')).json();
      if(w.state==='allowed'){say('JOINED');location.replace(location.pathname+location.search);return}
      if(w.state!=='pending'){say(w.state==='denied'?'THE HUB SAID NOT NOW':'THAT REQUEST EXPIRED',1);
                              go.disabled=false;return}
    }
  }catch(e){say('COULD NOT REACH THE HUB',1);go.disabled=false}
};
</script></body></html>
"""


if __name__ == "__main__":
    print(json.dumps({"lanOpen": lan_open(), "devices": devices()}, indent=1))
