#!/usr/bin/env python3
"""Sync Codec watch-state (resume position, watched movies/episodes) with the
LAN hub (the always-on desktop's codec-serve /_state endpoint).

Keys are canonical media paths (identical on every device), so this is a plain
merge: push local rows to the hub, get the merged authoritative state back,
write it into the local DB. Runs on app launch + quit + a timer. Short timeout
so it's a no-op when the hub is unreachable. Stdlib only (Hermes-runnable).
"""
import argparse, json, sqlite3
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse
from urllib.request import Request, urlopen
import codec_paths  # where codec's data lives (~/.local/share/codec)
codec_paths.install_hub_auth()   # a satellite's key rides every request to its hub

DB = codec_paths.DB
CFG = Path.home() / ".config/codec/config.json"
COLS = ["position", "duration", "aid", "sid", "speed", "zoom_mode",
        "last_mode", "watch_count", "completed", "last_played"]
SERVE_ROOT = "/mnt"


def canon(path: str) -> str:
    """Canonical, device-independent media key (mirrors ResumeStore::mediaKey)."""
    if "youtube.com/watch" in path:
        q = parse_qs(urlparse(path).query).get("v", [""])[0]
        if q:
            return f"yt:{q}"
    if "youtu.be/" in path:
        vid = urlparse(path).path.lstrip("/").split("/", 1)[0]
        if vid:
            return f"yt:{vid}"
    if path.startswith(("http://", "https://")):
        rest = path.split("://", 1)[1]
        # A path-less URL ('http://host') has no '/', so this used to return ''
        # — and EVERY such URL then collided on the same empty key, overwriting
        # each other. Fall back to the full path: non-empty and unique per URL.
        return unquote(rest.split("/", 1)[1]) if "/" in rest else path
    if path.startswith(SERVE_ROOT + "/"):
        return path[len(SERVE_ROOT) + 1:]
    return path


def _fold(a, b):
    """Two DB rows collided on the same canonical key — a legacy '/mnt/...' row
    and its migrated 'movies/...' twin on a not-yet-migrated DB. Keep the
    farther-along state instead of letting SELECT scan order decide (which could
    silently drop hours of progress). Farthest position wins; completed is OR'd
    (same media, same device — if either finished it, it's finished);
    watch_count grows; newer last_played breaks a genuine tie."""
    ap, bp = a.get("position") or 0, b.get("position") or 0
    win = a if (ap, a.get("last_played") or "") >= (bp, b.get("last_played") or "") else b
    row = dict(win)
    row["position"] = max(ap, bp)
    row["watch_count"] = max(a.get("watch_count") or 0, b.get("watch_count") or 0)
    row["completed"] = 1 if (a.get("completed") or b.get("completed")) else 0
    return row


def local_state(db):
    # Canonicalize on read so the client is correct even if the app has not
    # migrated this DB's legacy keys yet. Two legacy/migrated rows can canon to
    # the same key on a not-yet-migrated DB; fold them (farther-along wins)
    # rather than letting the last row in scan order clobber the first.
    out = {}
    for r in db.execute(f"SELECT path,{','.join(COLS)} FROM media_state"):
        k = canon(r[0])
        row = dict(zip(COLS, r[1:]))
        prev = out.get(k)
        out[k] = row if prev is None else _fold(prev, row)
    return out


def write_state(db, state):
    db.execute("""CREATE TABLE IF NOT EXISTS media_state (
        path TEXT PRIMARY KEY, position REAL DEFAULT 0, duration REAL DEFAULT 0,
        aid INTEGER DEFAULT -1, sid INTEGER DEFAULT -1, speed REAL DEFAULT 1.0,
        zoom_mode INTEGER DEFAULT -1, watch_count INTEGER DEFAULT 0,
        completed INTEGER DEFAULT 0, last_played TEXT, last_mode TEXT DEFAULT '')""")
    have = local_state(db)
    for key, inc in state.items():
        cur = have.get(key)
        if cur is not None:
            newer = (inc.get("last_played") or "") > (cur.get("last_played") or "")
            base = inc if newer else cur
            row = dict(base)
            # watch_count only ever grows.
            row["watch_count"] = max(inc.get("watch_count") or 0, cur.get("watch_count") or 0)
            # completed follows the NEWER writer (already in dict(base)) rather
            # than a blind OR of both — so an explicit "mark unwatched" (newest
            # timestamp, completed=0) actually clears it instead of a stale
            # completed=1 on another device OR-ing it back on forever.
            # position: never let a newer-but-EARLIER position silently rewind
            # resume across devices — take the farther of the two — UNLESS the
            # newer write is a deliberate finish (completed) or restart (reset
            # to ~0s), which is a lowering the user actually asked for.
            if not (base.get("completed") or (base.get("position") or 0) <= 1):
                row["position"] = max(inc.get("position") or 0, cur.get("position") or 0)
        else:
            row = inc
        db.execute(
            f"INSERT INTO media_state (path,{','.join(COLS)}) "
            f"VALUES (?,{','.join('?' * len(COLS))}) "
            f"ON CONFLICT(path) DO UPDATE SET "
            + ",".join(f"{c}=excluded.{c}" for c in COLS),
            [key] + [row.get(c) for c in COLS])
    db.commit()


def reachable_hub(lan, cfg):
    """The hub road that answers: its LAN address (syncUrl), else its Tailscale
    address (hubTailnet, or the Funnel name's :8200 — MagicDNS resolves it on
    the tailnet). The laptop's codec-sync.timer used to try the LAN only, so a
    whole trip's watch-state never merged until it came home."""
    import socket
    from urllib.parse import urlparse

    def answers(url, timeout):
        u = urlparse(url or "")
        if not u.hostname:
            return False
        try:
            socket.create_connection((u.hostname, u.port or 8200), timeout=timeout).close()
            return True
        except (OSError, ValueError):   # a malformed port raises ValueError
            return False

    if answers(lan, 1.5):
        return lan
    tnet = (cfg.get("hubTailnet") or "").rstrip("/")
    if not tnet and cfg.get("hubFunnel"):
        host = urlparse(cfg["hubFunnel"]).hostname
        if host:
            tnet = f"http://{host}:8200"
    if tnet and answers(tnet, 3.0):
        print(f"hub LAN unreachable — using the tailnet ({tnet})")
        return tnet
    return lan   # nothing answers: let the request fail and say so


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="", help="hub base URL (else config syncUrl / manifest urlBase)")
    ap.add_argument("--timeout", type=float, default=4.0)
    args = ap.parse_args()

    hub = args.url
    if not hub and CFG.exists():
        cfg = json.loads(CFG.read_text())
        hub = cfg.get("syncUrl", "")
        if not hub and cfg.get("remoteLibrary"):
            mp = Path(cfg["remoteLibrary"].replace("~", str(Path.home()), 1))
            if mp.exists():
                hub = json.loads(mp.read_text()).get("urlBase", "")
        hub = reachable_hub(hub, cfg)
    if not hub:
        print("no hub configured — skip"); return

    if not DB.exists():
        DB.parent.mkdir(parents=True, exist_ok=True)
        sqlite3.connect(DB).close()
    db = sqlite3.connect(DB)
    # The app has this same WAL DB open and writes to it every 10s (progress +
    # watch-time). WAL allows one writer at a time, so without a busy timeout a
    # write here that collides with the app's loses instantly to "database is
    # locked" and the merge is silently dropped. Now that a running app fires
    # this every 30s, that collision is no longer rare — wait it out.
    db.execute("PRAGMA busy_timeout=4000")
    mine = local_state(db)
    try:
        req = Request(hub.rstrip("/") + "/_state",
                      data=json.dumps(mine).encode(),
                      headers={"Content-Type": "application/json"}, method="POST")
        with urlopen(req, timeout=args.timeout) as r:
            merged = json.loads(r.read())
    except Exception as e:
        print(f"hub unreachable ({e}) — skip"); return
    write_state(db, merged)
    print(f"synced {len(merged)} entries with {hub}")


if __name__ == "__main__":
    main()
