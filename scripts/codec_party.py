#!/usr/bin/env python3
"""Run a hub-owned watch party — one clock, any number of screens.

The hub itself holds the clock, so nothing has to be playing locally. Your TV
and your friend's TV are both just followers, which is what makes "mine and
theirs at the same time" possible, and lets you be a viewer rather than the
projector.

    codec_party.py start "fight club"     # start a session on that title
    codec_party.py start --pick fight     # list matches instead of guessing
    codec_party.py play | pause           # drive the clock
    codec_party.py seek 1:23:00           # absolute (or seconds)
    codec_party.py skip -30               # relative, like a remote
    codec_party.py status
    codec_party.py stop
"""
import json
import sys
import urllib.error
import urllib.request

HUB = "http://127.0.0.1:8200"
PUB = "http://127.0.0.1:8299"


def post(path, body):
    req = urllib.request.Request(HUB + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=40) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        try:
            return json.load(e)
        except Exception:
            return {"ok": False, "error": f"HTTP {e.code}"}


def get(url):
    with urllib.request.urlopen(url, timeout=20) as r:
        return json.load(r)


def hhmmss(t):
    t = int(max(0, t))
    return f"{t//3600}:{(t%3600)//60:02d}:{t%60:02d}"


def parse_time(s):
    """'90', '1:30', '1:23:00' -> seconds."""
    parts = str(s).split(":")
    try:
        vals = [float(p) for p in parts]
    except ValueError:
        raise SystemExit(f"not a time: {s!r}")
    sec = 0.0
    for v in vals:
        sec = sec * 60 + v
    return sec


def find(term):
    """Match a library title. Returns [(index, label)]."""
    items = get(f"{HUB}/_manifest").get("entries") or []
    term = term.lower()
    hits = []
    for i, e in enumerate(items):
        if e.get("kind") == "show":
            continue
        label = " ".join(x for x in (e.get("show", ""), e.get("title", "")) if x)
        if term in label.lower():
            hits.append((i, f"{label}  ({e.get('subtitle','')})"))
    return hits


def status():
    st = get(f"{HUB}/party/status")
    if not st.get("active"):
        print("no party running")
        return 0
    # The LAN status already carries the clock (pos is projected to now). It
    # used to poll the PUBLIC guest route with no id — which made it a ghost
    # "guest" in the room and crashed (KeyError) while the room was locked.
    pos = float(st.get("pos") or 0)
    paused = bool(st.get("paused"))
    title = st.get("title") or "?"
    dur = st.get("dur") or 0
    print(f"  {title}")
    print(f"  {'paused' if paused else 'playing'} at {hhmmss(pos)}"
          + (f" / {hhmmss(dur)}" if dur else ""))
    print(f"  peers watching: {st.get('peers', 0)}")
    return 0


def main(argv):
    if not argv:
        return status()
    cmd = argv[0]

    if cmd == "start":
        args = argv[1:]
        pick = "--pick" in args
        args = [a for a in args if a != "--pick"]
        term = " ".join(args).strip()
        if not term:
            raise SystemExit("what should we watch? e.g. codec_party.py start 'fight club'")
        hits = find(term)
        if not hits:
            raise SystemExit(f"nothing in the library matches {term!r}")
        if pick or len(hits) > 1:
            for i, (idx, label) in enumerate(hits[:20]):
                print(f"  [{idx}] {label}")
            if len(hits) > 1 and not pick:
                print("\nseveral matches — rerun with the exact title, or use the "
                      "index:  codec_party.py start --index <n>")
                return 1
            return 0
        idx = hits[0][0]
        d = post("/party/start", {"mode": "hub", "index": idx, "paused": True})
        if not d.get("ok"):
            raise SystemExit(f"could not start: {d.get('error')}")
        print(f"\n  {d.get('title','')}")
        print(f"  invite: {d.get('inviteUrl','(funnel down)')}")
        print("\n  cast that link on each TV, then:  codec_party.py play")
        return 0

    if cmd == "--index" or cmd == "index":
        idx = int(argv[1])
        d = post("/party/start", {"mode": "hub", "index": idx, "paused": True})
        if not d.get("ok"):
            raise SystemExit(f"could not start: {d.get('error')}")
        print(f"  {d.get('title','')}\n  invite: {d.get('inviteUrl','')}")
        return 0

    if cmd == "stop":
        st = get(f"{HUB}/party/status")
        post("/party/stop", {"token": st.get("token", "")})
        print("party ended.")
        return 0

    if cmd == "status":
        return status()

    # everything else drives the clock
    st = get(f"{HUB}/party/status")
    if not st.get("active"):
        raise SystemExit("no party running — codec_party.py start <title>")
    tok = st.get("token", "")
    if cmd in ("play", "pause"):
        d = post("/party/cmd", {"token": tok, "op": cmd})
    elif cmd == "seek":
        d = post("/party/cmd", {"token": tok, "op": "seek",
                                "arg": parse_time(argv[1])})
    elif cmd == "skip":
        d = post("/party/cmd", {"token": tok, "op": "skip", "arg": float(argv[1])})
    elif cmd == "rate":
        d = post("/party/cmd", {"token": tok, "op": "rate", "arg": float(argv[1])})
    else:
        raise SystemExit(f"unknown command {cmd!r}")
    if not d.get("ok"):
        raise SystemExit(f"failed: {d.get('error')}")
    print(f"  {'paused' if d['paused'] else 'playing'} at {hhmmss(d['pos'])}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except urllib.error.URLError as e:
        print(f"hub not reachable at {HUB}: {e}", file=sys.stderr)
        raise SystemExit(1)
