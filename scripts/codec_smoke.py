#!/usr/bin/env python3
"""Play a few seconds down every lane and DECODE what comes back.

The selfcheck mostly asks whether code exists. That is the wrong question for
this program, because codec's failure mode is silence — three separate bugs
shipped and lived here without ever printing an error:

  - `src` unbound in the YouTube branch: every YouTube cast dropped the
    connection with no reply. A grep for "kind == 'yt'" passes anyway.
  - a 4K rung left in a cast ladder: the TV picks it, buffers forever, and
    looks exactly like a bad network.
  - partyMediaJson() calling a YouTube video kind:"file": the host watched it
    fine and every guest got nothing.

None of the three could be caught by reading source. All three CAN be caught
by asking the hub for the bytes and handing them to a decoder — a lane that
serves a frame is working, and a lane that doesn't, isn't.

So: for each lane, fetch the playlist, fetch a real segment, and ffprobe it.
Read-only, no device needed, ~1 minute.

    python3 scripts/codec_smoke.py
"""
import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import quote, urljoin
import codec_paths  # where codec's data lives (~/.local/share/codec)

HUB = "http://127.0.0.1:8200"
MANIFEST = codec_paths.MANIFEST
# A short, famously-present video. The lane only has to START.
YT = "dQw4w9WgXcQ"
# Cast receivers announce themselves with this header, and the hub shapes the
# ladder off it — spoofing it is the only way to exercise the REAL cast path
# without a television in the room.
CAST_HDRS = {"CAST-DEVICE-CAPABILITIES": '{"display_supported":true}',
             "Origin": "https://www.gstatic.com"}

fails = []


def check(name, ok, detail=""):
    print(f"  {'ok  ' if ok else 'FAIL'}  {name}{'  — ' + detail if detail else ''}")
    if not ok:
        fails.append(name)
    return ok


def get(url, headers=None, timeout=300):
    req = urllib.request.Request(url, headers=headers or {})
    return urllib.request.urlopen(req, timeout=timeout).read()


def post(path, **body):
    req = urllib.request.Request(HUB + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        return json.loads(urllib.request.urlopen(req, timeout=120).read())
    except urllib.error.HTTPError as e:
        return json.loads(e.read() or b"{}")


def decode(blob, suffix=".m4s"):
    """Hand bytes to ffprobe. Returns (codec, height, frames) or None.

    Counting FRAMES, not just parsing a header: a truncated or zero-length
    segment still has a readable container.
    """
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as f:
        f.write(blob)
        p = f.name
    try:
        out = subprocess.run(
            ["/usr/bin/ffprobe", "-v", "error", "-count_frames",
             "-select_streams", "v:0", "-show_entries",
             "stream=codec_name,height,nb_read_frames", "-of", "json", p],
            capture_output=True, text=True, timeout=120).stdout
        st = (json.loads(out or "{}").get("streams") or [{}])[0]
        n = int(st.get("nb_read_frames") or 0)
        return (st.get("codec_name", "?"), int(st.get("height") or 0), n)
    except Exception:
        return None
    finally:
        os.unlink(p)


def first_segment(master_url, body, headers=None):
    """Follow a master -> media playlist -> init+segment, and return the bytes.

    fMP4 segments are meaningless alone; the init header carries the codec
    description. Concatenating them is what an actual player does.
    """
    lines = [l.strip() for l in body.splitlines() if l.strip()]
    if any(l.startswith("#EXT-X-STREAM-INF") for l in lines):
        var = next(l for l in lines if not l.startswith("#"))
        master_url = urljoin(master_url, var)
        body = get(master_url, headers).decode("utf-8", "replace")
        lines = [l.strip() for l in body.splitlines() if l.strip()]
    init = b""
    for l in lines:
        if l.startswith("#EXT-X-MAP:"):
            uri = l.split('URI="', 1)[1].split('"', 1)[0]
            init = get(urljoin(master_url, uri), headers)
    seg = next((l for l in lines if not l.startswith("#")), None)
    if not seg:
        return None, ""
    return init + get(urljoin(master_url, seg), headers), seg


def lane(name, url, headers=None, expect=None):
    """Fetch a playlist, pull one segment, decode it."""
    try:
        body = get(url, headers).decode("utf-8", "replace")
    except Exception as e:
        return check(f"{name}: playlist", False, str(e)[:70])
    if not check(f"{name}: playlist", body.startswith("#EXTM3U"),
                 f"{len(body.splitlines())} lines"):
        return False
    if expect:
        expect(body)
    try:
        blob, segname = first_segment(url, body, headers)
    except Exception as e:
        return check(f"{name}: segment", False, str(e)[:70])
    if not check(f"{name}: segment has bytes", bool(blob) and len(blob) > 4096,
                 f"{len(blob or b''):,}B {segname}"):
        return False
    d = decode(blob, os.path.splitext(segname.split("?")[0])[1] or ".m4s")
    return check(f"{name}: DECODES", bool(d) and d[2] > 0,
                 f"{d[0]} {d[1]}p, {d[2]} frames" if d else "ffprobe read nothing")


# ── pick a real film out of the library ─────────────────────────────────────
_mani = json.loads(MANIFEST.read_text())
man = _mani.get("entries")
if not isinstance(man, list):
    print("manifest has no 'entries' array — schema changed? (safety net can't run)")
    sys.exit(1)
movies = [e for e in man if e.get("kind") == "movie" and e.get("url")]
from urllib.parse import urlparse, unquote
pick = next((e for e in movies
             if os.path.exists("/mnt" + unquote(urlparse(e["url"]).path))), None)
if not pick:
    print("no readable film in the manifest — are the drives mounted?")
    raise SystemExit(2)
rel = unquote(urlparse(pick["url"]).path)
path = "/mnt" + rel
print(f"\ncodec smoke — {pick['title'][:44]}\n")

# ── 1. the local file itself ────────────────────────────────────────────────
# What the app hands to mpv, and what the range server serves to a browser or
# a direct-play cast. If this can't decode, nothing downstream can.
print("local file")
d = decode(open(path, "rb").read(2 << 20), os.path.splitext(path)[1])
check("file decodes off disk", bool(d) and d[1] > 0,
      f"{d[0]} {d[1]}p" if d else "no video stream")
try:
    # ⚠ the manifest URL path is ALREADY the path the range server serves —
    # rooted at the media dir, with no /mnt prefix. Prefixing it 404s.
    req = urllib.request.Request(HUB + quote(rel),
                                 headers={"Range": "bytes=0-262143"})
    r = urllib.request.urlopen(req, timeout=60)
    body = r.read()
    check("range server serves it", r.status == 206 and len(body) == 262144,
          f"HTTP {r.status}, {len(body):,}B")
except Exception as e:
    check("range server serves it", False, str(e)[:70])

# ── 2. the cast lane ────────────────────────────────────────────────────────
# The ladder a television gets. Chromecast built-in decodes h264 to 1080p and
# no further, so a rung above that is a lane that buffers forever.
print("\ncast lane (spoofing a receiver's headers)")


def cast_ladder_is_sane(body):
    hs = [int(l.split("x")[1].split(",")[0])
          for l in body.splitlines() if "RESOLUTION=" in l
          for l in [l.split("RESOLUTION=")[1]]]
    check("cast ladder is capped at 1080", not hs or max(hs) <= 1080,
          f"rungs {sorted(set(hs), reverse=True)}" if hs else "single variant")
    check("cast ladder carries no HDR", "smpte2084" not in body.lower()
          and "PQ" not in body, "")


lane("cast", f"{HUB}/hls/pl.m3u8?src={quote(rel)}&maxh=1080&sdr=1",
     CAST_HDRS, cast_ladder_is_sane)

# ── 3. the youtube lane ─────────────────────────────────────────────────────
# The branch that raised UnboundLocalError for weeks in total silence.
print("\nyoutube lane")
lane("youtube", f"{HUB}/hls/pl.m3u8?kind=yt&v={YT}&maxh=720")

# The LAN yt lane above never touches the ROAMING path — a YouTube cast away
# from home rides /r/<token>/hls/pl?kind=yt on the token-scoped public surface,
# so a regression there (a dead LAN base, a broken kind=yt branch) would pass
# green. Mint a browse token and pull that exact lane over :8299.
print("\nyoutube lane (roaming / public surface)")
PUB = "http://127.0.0.1:8299"
_b = post("/browse/start", hours=1, new=False)
_tok = (_b.get("url") or "").rstrip("/").rsplit("/", 1)[-1] if "/r/" in (_b.get("url") or "") else ""
if check("browse token minted", bool(_tok), _tok[:14]):
    lane("youtube/roaming", f"{PUB}/r/{_tok}/hls/pl.m3u8?kind=yt&v={YT}&maxh=720")

# ── 4. the party lane ───────────────────────────────────────────────────────
# What a guest's browser pulls. Started PAUSED so nothing moves on the TV.
print("\nparty lane")
idx = man.index(pick)
s = post("/party/start", mode="hub", index=idx, paused=True)
tok = s.get("token", "")
if check("party starts", bool(tok), s.get("title", "")[:40]):
    try:
        lane("party", f"{HUB}/p/{tok}/hls/pl.m3u8")
        # and the same room, switched to a YouTube video — the kind:"file"
        # bug looked perfect on the host and served guests nothing.
        r = post("/party/cmd", token=tok, op="queue",
                 items=[{"vid": YT}])
        if check("party accepts a youtube item", r.get("ok"), str(r)[:50]):
            lane("party/youtube", f"{HUB}/p/{tok}/hls/pl.m3u8")
    finally:
        post("/party/stop", token=tok)
        print("  party stopped")

# ── 5. presence and handoff ─────────────────────────────────────────────────
# Not a lane — nothing plays here — but the same rule applies: exercise the
# behaviour, don't read the code. The handshake is the part with a bug in it:
# the origin publishes every ~2s and so RE-ADDS ITSELF a beat after being
# handed off, and only an acknowledgement can tell "still playing" apart from
# "hasn't heard yet".
print("\npresence")
A, B = "smoke-a", "smoke-b"
try:
    post("/now/bye", device=A)
    post("/now/bye", device=B)
    post("/now", device=A, name="ScreenA", title="Some Film", pos=600.0,
         dur=5000.0, media={"kind": "file", "key": "x/y.mkv"})

    def now_for(dev):
        d = json.loads(get(f"{HUB}/party/status?dev={dev}").decode())
        return [n["device"] for n in d.get("now", [])]

    check("the other screen sees it", now_for(B) == [A], str(now_for(B)))
    check("a screen is never offered its own film", now_for(A) == [])
    r = post("/now/resume", device=B, **{"from": A})
    check("resume hands back media and position",
          r.get("ok") and r.get("pos") == 600.0, str(r.get("from")))
    s = post("/now", device=A, name="ScreenA", title="Some Film", pos=602.0)
    check("origin is told to stop", s.get("stop") == 1, str(s))
    check("origin can't re-appear before acknowledging", now_for(B) == [],
          str(now_for(B)))
    check("and can't be taken twice",
          post("/now/resume", device=B, **{"from": A}).get("error") == "gone")
    s = post("/now", device=A, name="ScreenA", title="Next Film", pos=3.0,
             stopAck=1)
    check("acknowledging puts it back in play",
          s.get("stop") == 0 and now_for(B) == [A], str(now_for(B)))
finally:
    post("/now/bye", device=A)
    post("/now/bye", device=B)

print(f"\n{'ALL LANES PLAY' if not fails else 'FAILED: ' + ', '.join(fails)}\n")
sys.exit(1 if fails else 0)
