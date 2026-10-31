#!/usr/bin/env python3
"""Pull the hub's library manifest (and any art it references) to this device.

The old flow was push-only: the hub rsync'd the manifest at reconcile/nightly
time, so a satellite that was offline at that moment stayed stale forever —
ghosts of deleted movies, missing new ones, dead URLs for upgraded files. This
script inverts it: the SATELLITE asks the hub for the current manifest at app
launch (and on demand), so one launch with the hub reachable is always enough
to catch up. The push path can stay as a bonus; this is the guarantee.

Exit codes (the app branches on these):
  0 = manifest updated (app should reload + toast)
  2 = hub unreachable / no hub configured (silent no-op, keep local copy)
  3 = manifest already current (silent)
Stdlib only (Hermes-runnable).
"""
import json
import sys
import os
from pathlib import Path
from urllib.parse import quote, urlparse, parse_qs
from urllib.request import urlopen
import codec_paths  # where codec's data lives (~/.local/share/codec)
codec_paths.install_hub_auth()   # a satellite's key rides every request to its hub

CFG = Path.home() / ".config/codec/config.json"


def fetch(url, timeout=8.0):
    with urlopen(url, timeout=timeout) as r:
        return r.read()


ART_DIR = Path.home() / ".cache/codec/art"


def reachable_hub(lan, cfg):
    """The hub road that answers: its LAN address (syncUrl), else its Tailscale
    address (hubTailnet, or the Funnel name's :8200 — MagicDNS resolves it on
    the tailnet). Away from home the manifest + art pull used to give up on the
    LAN address alone and the satellite's library stayed stale for the trip."""
    import socket

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
    return lan   # nothing answers: the fetch below fails and says so


def art_target(ref):
    """(local file, hub filename) for a manifest art reference, or None.

    The manifest carries art as a hub URL — "http://<hub>:8200/art?f=<hash>.jpg"
    — and Theme::artLocal resolves that to ~/.cache/codec/art/<hash>.jpg. This
    loop predated that and still treated the field as a LOCAL PATH, so
    Path(ref).name came out as the whole query string ("art?f=<hash>.jpg") and
    every fetch asked the hub for "/art?f=art%3Ff%3D<hash>.jpg". All 1770 art
    files failed on 2026-09-16 and the satellite had no posters at all, while
    the same URL fetched by hand returned 200 — the network was never the
    problem, the two halves of the contract had simply drifted apart.

    Legacy local-path manifests still work: anything that is not a URL is used
    as the path it always was.
    """
    if not ref:
        return None
    if ref.startswith("http://") or ref.startswith("https://"):
        name = parse_qs(urlparse(ref).query).get("f", [""])[0]
        name = os.path.basename(name)
        if not name:
            return None
        return ART_DIR / name, name
    local = Path(ref)
    return local, local.name


def main():
    try:
        cfg = json.loads(CFG.read_text())
    except Exception:
        print("no config — skip"); return 2
    hub = (cfg.get("syncUrl") or "").rstrip("/")
    mp = cfg.get("remoteLibrary") or ""
    if not hub or not mp:
        print("not a satellite (no syncUrl/remoteLibrary) — skip"); return 2
    hub = reachable_hub(hub, cfg)
    manifest_path = Path(mp.replace("~", str(Path.home()), 1))

    try:
        raw = fetch(hub + "/_manifest")
        data = json.loads(raw)
        assert isinstance(data.get("entries"), list)
    except Exception as e:
        print(f"hub unreachable ({e}) — keeping local copy"); return 2

    manifest_current = False
    try:
        manifest_current = manifest_path.exists() and manifest_path.read_bytes() == raw
    except Exception:
        pass
    if manifest_current:
        # A byte-identical manifest is NOT enough to skip the pull: art that
        # failed on an earlier run (a transient hub/network hiccup) would then
        # never be retried, because this short-circuit fires forever — that is
        # how a title ends up permanently logo-less (the "Reacher has no title
        # art" case). Only skip when every referenced art file is on disk;
        # otherwise fall through and the fetch loop below picks up the missing
        # ones (it already fetches only what's absent).
        missing = 0
        for e in data["entries"]:
            for key in ("poster", "fanart", "clearlogo"):
                t = art_target(e.get(key) or "")
                if t and not t[0].exists():
                    missing += 1
        if not missing:
            print("manifest already current"); return 3
        print(f"manifest current but {missing} art file(s) missing — refetching")

    # Art first, manifest last: if we die mid-way the old manifest still
    # matches the art on disk. Only fetch what's missing (basenames are
    # content hashes, so an existing file never needs refreshing).
    fetched = failed = 0
    for e in data["entries"]:
        for key in ("poster", "fanart", "clearlogo"):
            p = e.get(key) or ""
            if not p:
                continue
            t = art_target(p)
            if not t:
                continue
            local, remote_name = t
            if local.exists():
                continue
            try:
                img = fetch(hub + "/art?f=" + quote(remote_name), timeout=15)
                local.parent.mkdir(parents=True, exist_ok=True)
                tmp = local.with_suffix(".part")
                tmp.write_bytes(img)
                tmp.replace(local)
                fetched += 1
            except Exception:
                failed += 1  # a missing poster is cosmetic; keep going

    # Shrink guard: the write is atomic, but atomically replacing a full
    # library with a near-empty one (a partial hub export, a mid-write read) is
    # still data loss. Refuse a manifest that lost more than half its entries
    # versus the copy we already have.
    new_n = len(data.get("entries") or [])
    if manifest_path.exists():
        try:
            old_n = len(json.loads(manifest_path.read_text()).get("entries") or [])
        except Exception:
            old_n = 0
        if old_n and new_n < old_n * 0.5:
            print(f"refusing shrunken manifest ({new_n} vs {old_n} local) — "
                  "keeping local copy")
            return 2
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = manifest_path.with_suffix(".tmp")
    tmp.write_bytes(raw)
    tmp.replace(manifest_path)

    # Prune orphaned art: the fetch loop only ADDS files, so art whose title
    # left the library — or whose URL changed (basenames are content hashes, so
    # an upgrade lands under a NEW name and orphans the old) — accumulates
    # forever. Delete anything in the art dir the current (validated) manifest
    # no longer references. Runs after the shrink guard so a bad manifest can't
    # trigger a mass delete.
    # Resolved through art_target, like the fetch: the refs are hub URLs now,
    # and Path(url).parent ("http:/<hub>:8200") made this a silent no-op —
    # superseded art piled up on the satellite forever.
    referenced, art_dirs, pruned = set(), set(), 0
    for e in data["entries"]:
        for key in ("poster", "fanart", "clearlogo"):
            t = art_target(e.get(key) or "")
            if t:
                referenced.add(t[0].name)
                art_dirs.add(t[0].parent)
    # And never a mass delete: a manifest whose art fields came out blank (a
    # half-broken export with the right entry count passes the shrink guard)
    # would otherwise empty the art cache in one run.
    try:
        have = sum(1 for d in art_dirs for f in d.iterdir()
                   if f.is_file() and f.suffix != ".part")
    except OSError:
        have = 0
    if have and len(referenced) < have * 0.5:
        print(f"not pruning art: the manifest references {len(referenced)} of "
              f"{have} local files — that looks like a broken export")
        art_dirs = set()
    for d in art_dirs:
        try:
            for f in d.iterdir():
                if f.is_file() and f.suffix != ".part" and f.name not in referenced:
                    f.unlink(missing_ok=True)
                    pruned += 1
        except OSError:
            pass

    print(f"manifest updated — {len(data['entries'])} entries, "
          f"art +{fetched}" + (f" ({failed} failed)" if failed else "")
          + (f", pruned {pruned}" if pruned else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
