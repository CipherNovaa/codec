#!/usr/bin/env python3
"""Watch-party SEATS (codec_serve.py, "Seats"): who gets a say in the room.

A stray invite link — a forgotten background tab, a second device — must not be
able to freeze the room, drag the cushion, keep an empty room rolling, or vote
it backwards; the host's DROP and LOCK ROOM must hold. Pinned here because the
failure is invisible until a real night goes wrong.

    python3 tests/test_party_seats.py

Runs codec_serve's LAN + public listeners in-process on spare loopback ports,
with HOME pointed at a scratch dir (the real party.json is never read or
written) and the clocks scaled down so the whole thing takes about a minute.
"""
import json, os, pathlib, sys, tempfile, threading, time, urllib.request
from functools import partial
from urllib.parse import quote

# BEFORE the import: codec_serve reads ~/.local/share/myOS/codec/party.json at
# module load.
os.environ["HOME"] = tempfile.mkdtemp(prefix="partyseats-")
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "scripts"))
import codec_serve as cs

# Scaled-down clocks so the whole suite runs in about a minute.
cs.PARTY_SEAT_AFTER = 4.0
cs.PARTY_AWAY_AFTER = 2.0
cs.PARTY_OFF_AFTER = 3.0
cs.PARTY_SEEK_GRACE = 1.0
cs.PARTY_STALL_AFTER = 1.0
cs.PARTY_WAIT_MAX = 3.0
cs.PARTY_WAIT_COOLDOWN = 2.0
cs.PARTY_PEER_WINDOW = 30
cs.PARTY_IDLE_PAUSE = 3

D = os.path.join(os.environ["HOME"], "mnt")
os.makedirs(D, exist_ok=True)
lan = cs.ThreadingHTTPServer(("127.0.0.1", 0), partial(cs.RangeHandler, directory=D))
pub = cs.ThreadingHTTPServer(("127.0.0.1", 0), partial(cs.RangeHandler, directory=D))
pub.codec_party = True
for s in (lan, pub):
    threading.Thread(target=s.serve_forever, daemon=True).start()
LAN = f"http://127.0.0.1:{lan.server_address[1]}"
PUB = f"http://127.0.0.1:{pub.server_address[1]}"

FAILS = []


def check(cond, what):
    print(("  ok   " if cond else "  FAIL ") + what)
    if not cond:
        FAILS.append(what)


def post(path, body):
    r = urllib.request.Request(LAN + path, data=json.dumps(body).encode(),
                               headers={"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(r, timeout=5).read() or b"{}")


def get(base, path):
    return json.loads(urllib.request.urlopen(base + path, timeout=5).read() or b"{}")


TOK = post("/party/start", {"mode": "hub", "pos": 100.0, "paused": False,
                            "media": {"kind": "test", "title": "Test", "dur": 7200}})["token"]


def room_target():
    """Where an in-step screen sits right now: the hub clock minus the cushion."""
    with cs._PARTY_LOCK:
        return cs._party_now_pos() - float(cs._PARTY.get("room_lag", 0.3))


class Screen:
    def __init__(self, gid, name="", base=PUB, v=1, w=1, cu=0.5, by=""):
        self.gid, self.name, self.base, self.v, self.w, self.cu, self.by = \
            gid, name, base, v, w, cu, by
        self.stall = False
        self.off = 0.0        # seconds out of step
        self.say_p = True

    def poll(self, extra=""):
        q = f"/p/{TOK}/state?g={self.gid}&n={quote(self.name)}&w={self.w}&v={self.v}&cu={self.cu}"
        if self.say_p:
            q += f"&p={room_target() - self.off:.2f}"
        if self.stall:
            q += "&sl=1"
        if self.by:
            q += f"&by={self.by}"
        return get(self.base, q + extra)


def tick(screens, secs, step=0.25):
    end = time.time() + secs
    while time.time() < end:
        for s in screens:
            s.poll()
        time.sleep(step)


def st(gid):
    with cs._PARTY_LOCK:
        g = (cs._PARTY.get("guests") or {}).get(gid)
        return cs._party_seat_state(g, time.time()) if g else None


def status():
    return get(LAN, "/party/status?cs=0")


host = Screen("app-host", "Alex", base=LAN)
a = Screen("ga", "Riley")
b = Screen("gb", "Ryu")
stray = Screen("gs", "Riley", v=0, cu=12)      # a forgotten background tab

print("1. seats are earned")
tick([host, a, b, stray], 1.5)
check(st("app-host") == "seated", "the host app on the LAN is seated straight away")
check(st("ga") == "joining" and st("gb") == "joining", "remote guests start out joining")
tick([host, a, b, stray], 1.0)
check(st("gs") == "away", "a hidden tab is away, not present")
tick([host, a, b, stray], 2.5)
check(st("ga") == "seated" and st("gb") == "seated", "remote guests are seated after playing in step")
check(st("gs") == "away", "the hidden tab never earns a seat")
s = status()
check(s["peers"] == 3, f"the room counts 3 watching, not the hidden tab ({s['peers']})")
check(s["roomLagMs"] < 3000, f"the hidden tab's 12 s cushion is ignored (lag {s['roomLagMs']} ms)")

print("2. a stray can't make the room wait")
stray.v = 1
stray.stall = True        # visible, stuck buffering, never in step
stray.off = 30
b.stall = True
tick([host, a, b, stray], 2.0)
with cs._PARTY_LOCK:
    waiting = bool(cs._PARTY.get("wait_since"))
check(not waiting, "one real guest + a stalled stray is not a majority any more")
check(st("gs") == "joining", "the visible stray is joining, never seated")
b.stall = False
stray.stall = False
stray.v = 0
tick([host, a, b, stray], 0.5)

print("3. a shared stall waits once, then those screens re-earn")
a.stall = b.stall = True
tick([host, a, b, stray], 1.6)
with cs._PARTY_LOCK:
    waiting = bool(cs._PARTY.get("wait_since"))
    wf = list(cs._PARTY.get("waiting_for") or [])
check(waiting, f"two of three seated screens stalled → the room waits ({wf})")
a.stall = b.stall = False
tick([host, a, b, stray], 1.0)
with cs._PARTY_LOCK:
    waiting = bool(cs._PARTY.get("wait_since"))
check(not waiting, "the room rolls again once they recover")
check(st("ga") == "joining" and st("gb") == "joining", "the screens it waited for give their seats up")
check(st("app-host") == "seated", "the host keeps its seat")
time.sleep(1.2)   # past the grace after the resume command
a.stall = b.stall = True
tick([host, a, b, stray], 1.6)
with cs._PARTY_LOCK:
    waiting = bool(cs._PARTY.get("wait_since"))
check(not waiting, "the same two stalling again straight away does NOT freeze the room")
a.stall = b.stall = False
tick([host, a, b, stray], 5.5)
check(st("ga") == "seated" and st("gb") == "seated", "they earn their seats back by playing in step")

print("4. votes")
r = stray.poll("&vote=rewind")
n_after_stray = r.get("vote", {}).get("n")
check(n_after_stray == 0, f"a spectator's rewind vote isn't counted (n={n_after_stray})")
r = a.poll("&vote=rewind")
check(r.get("vote", {}).get("n") == 1, f"a seated guest's vote counts (n={r.get('vote')})")

print("5. lock + drop")
post("/party/lock", {"on": True})
newbie = Screen("gn", "Stranger")
r = newbie.poll()
check(r.get("locked") is True and r.get("active") is False, "a new screen can't join a locked room")
tv = Screen("tv123", "Riley's TV", by="ga")
r = tv.poll()
check(r.get("active") is True, "a guest's own TV (by=their id) gets in while locked")
lanbie = Screen("app-laptop", "Laptop", base=LAN)
r = lanbie.poll()
check(r.get("active") is True, "a screen in the house gets in while locked")
with cs._PARTY_LOCK:
    cs._PARTY["guests"].pop("gb", None)      # as if Ryu's phone slept past the roster
r = b.poll()
check(r.get("active") is True, "a known guest coming back from a long sleep gets in")
post("/party/drop", {"id": "ga"})
r = a.poll()
check(r.get("removed") is True, "a dropped guest is told so")
r = tv.poll()
check(r.get("removed") is True, "…and so is their TV")
check(st("ga") is None and st("tv123") is None, "both are gone from the roster")
post("/party/lock", {"on": False})
r = newbie.poll()
check(r.get("active") is True, "unlocked, newcomers get in again")
r = a.poll()
check(r.get("removed") is True, "a dropped id stays dropped after the unlock")

print("6. the roster is full")
with cs._PARTY_LOCK:
    cs._PARTY["guests"] = {k: g for k, g in cs._PARTY["guests"].items() if k in ("app-host", "gb")}
fills = [Screen(f"h{i}", f"Tab{i}", v=0) for i in range(10)]
for f in fills:
    f.poll()
    time.sleep(0.02)
with cs._PARTY_LOCK:
    n = len(cs._PARTY["guests"])
check(n == 12, f"twelve screens in the roster ({n})")
time.sleep(2.2)        # the hidden tabs are now away
late = Screen("glate", "Late Friend")
r = late.poll()
with cs._PARTY_LOCK:
    gs = cs._PARTY["guests"]
    ok = "glate" in gs and "h0" not in gs and len(gs) == 12
check(ok, "a newcomer bumps the longest-idle hidden tab, not a real viewer")

print("7. the room empties")
with cs._PARTY_LOCK:
    cs._PARTY["guests"] = {k: g for k, g in cs._PARTY["guests"].items() if k == "gs"}
    cs._PARTY["peers"] = {}
    cs._PARTY["last_peer"] = time.time()
    cs._PARTY["updated"] = time.time()
for _ in range(24):          # only the hidden stray keeps polling (> away + idle-pause)
    stray.poll()
    time.sleep(0.25)
did = cs._party_sweep_once()
with cs._PARTY_LOCK:
    paused = cs._PARTY.get("paused")
check(did == "pause" and paused, f"a room with only a hidden tab pauses itself ({did})")
card = Screen("gc", "Riley", w=0)
with cs._PARTY_LOCK:
    cs._PARTY["paused"] = False
    cs._PARTY["epoch_ms"] = cs._now_ms()
    cs._PARTY["last_peer"] = time.time()
    cs._PARTY["updated"] = time.time()
for _ in range(16):
    card.poll()
    time.sleep(0.25)
did = cs._party_sweep_once()
check(did == "pause", f"…and so does one where someone only sits on the invite card ({did})")

print("8. payloads")
s = status()
row = next((r for r in s.get("room", []) if r["id"] == "gc"), None)
check(row is not None and row["st"] == "card" and "earn" in row and "behind" in row,
      f"the host roster row carries state/earn/behind ({row})")
r = card.poll()
me = next((x for x in r.get("room", []) if x.get("me")), None)
check(me is not None and me.get("st") == "card" and "tv" in me and "id" in me
      and me["id"] != "gc", f"the guest roster has states and still no raw ids ({me})")

print("9. a public request can't speak for the house (audit 2026-10-10)")
post("/party/lock", {"on": False})
host = Screen("codec-testhost", "Alex", base=LAN)
host.poll()
post("/party/lock", {"on": True})
def roster_ids():
    return {r["id"] for r in status().get("room", [])}
r = get(PUB, f"/p/{TOK}/state?g=codec-testhost&n=Mallory&w=1&v=1&cu=12")
with cs._PARTY_LOCK:
    hrow = dict((cs._PARTY.get("guests") or {}).get("codec-testhost") or {})
check(hrow.get("name") == "Alex" and hrow.get("lan") and hrow.get("cu", 0) < 12,
      f"the host's own id over Funnel can't take over its row ({hrow.get('name')}, lan={hrow.get('lan')}, cu={hrow.get('cu')})")
r = get(PUB, f"/p/{TOK}/state?g=strangerX&by=codec-testhost&n=X&w=1&v=1")
check(r.get("locked") and "strangerX" not in roster_ids(),
      "a stranger naming the host as `by` stays locked out")
r = get(PUB, f"/p/{TOK}/state?g=192.168.0.5&n=Y&w=1&v=1")
check("192.168.0.5" not in roster_ids(), "a LAN-shaped id over Funnel is refused")
post("/party/lock", {"on": False})
before = roster_ids()
r = get(PUB, f"/p/{TOK}/state?w=1&v=1")
check(r.get("active") and roster_ids() == before,
      "an idless public request gets the state but no presence")

print("10. a film change holds everyone until they have it loaded (2026-10-10)")
cs.PARTY_LOAD_MAX = 3.0
ann, bo = Screen("loadA", "Ann"), Screen("loadB", "Bo")
tick([ann, bo], 1.0)
def change_film():
    with cs._PARTY_LOCK:
        cs._PARTY["seq"] += 1
        cs._PARTY["media"] = {"kind": "file", "key": "x/next.mkv", "title": "Next", "dur": 600.0}
        cs._PARTY["pos"] = 0.0
        cs._party_begin_load(time.time(), True)
        ld = cs._PARTY["loading"]
        both = "loadA" in ld["need"] and "loadB" in ld["need"]
        # earlier sections' screens are still "present" (a 30 s window) and
        # the hold rightly waits for them too — this section is about Ann and Bo
        ld["need"] = ["loadA", "loadB"]
        return ld["seq"], both
seq, both = change_film()
check(both, "the hold waits for every screen that's present")
r = ann.poll()
check(r.get("loading") and r.get("paused") and r.get("load_seq") == seq,
      f"the room holds on the new film's first frame (loading={r.get('loading')}, paused={r.get('paused')})")
r = ann.poll(f"&rdy={seq}")
check(r.get("loading"), "one screen ready isn't enough while another is still loading")
r = bo.poll(f"&rdy={seq + 7}")
check(r.get("loading"), "a ready report for a different change doesn't count")
r = bo.poll(f"&rdy={seq}")
check(not r.get("loading") and not r.get("paused"),
      f"everyone ready: the room starts (loading={r.get('loading')}, paused={r.get('paused')})")
seq, _ = change_film()
ann.poll(f"&rdy={seq}")
time.sleep(3.3)
did = cs._party_sweep_once()
s = status()
check(did == "loaded" and not s.get("paused"),
      f"a screen that never gets there can't hold the room past the cap ({did}, paused={s.get('paused')})")
seq, _ = change_film()
post("/party/cmd", {"token": TOK, "op": "seek", "arg": 42})
r = ann.poll()
check(not r.get("loading") and not r.get("paused"),
      f"a seek mid-hold ends it and the room still plays (audit: it froze) (paused={r.get('paused')})")
seq, _ = change_film()
post("/party/cmd", {"token": TOK, "op": "pause"})
r = ann.poll()
check(not r.get("loading") and r.get("paused"), "the host pausing mid-hold wins (no hold, stays paused)")

# ── a television's paused card reads the state doc, not the LOAD ───────────
# The party face on a TV (the guest web player's dock, hold and card) paints
# from the clock poll: the money line and the art flags have to be there, as
# numbers and booleans, for a film the room describes with no such facts.
st = get(PUB, f"/p/{TOK}/state?g=tvface")
m = st.get("media") or {}
check(isinstance(m.get("budget"), int) and isinstance(m.get("revenue"), int),
      "the state doc carries budget/revenue as integers (0 when unknown)")
check(all(k in m for k in ("hasPoster", "hasLogo", "hasBackdrop", "director", "genres")),
      "the state doc carries the paused card's facts and art flags")
st2 = get(PUB, f"/p/{TOK}/state?g=tvface&cs={int(st.get('chat_seq') or 0)}")
check(st2.get("chat") == [], "cs= on a poll returns only chat newer than the caller has")

print()
print("FAILED:" if FAILS else "ALL PASSED", *FAILS, sep="\n  ")
sys.exit(1 if FAILS else 0)
