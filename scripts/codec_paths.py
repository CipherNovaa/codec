#!/usr/bin/env python3
"""Where codec keeps its data — for every script that reads or writes it.

codec began inside myOS and kept its data (codec.db, the manifest, the queue,
arrivals.json …) in ~/.local/share/myOS/codec. It's its own program now: the
app moves the data to ~/.local/share/codec the first time a new build starts,
and leaves the old folder as a link to the new one (src/main.cpp,
migrateDataDir).

Until that move has happened, the old folder is still the real one — and a
script must NOT start a fresh, empty database in the new folder before it does
(the app would then see two). So the rule is: wherever the database actually
is. The old folder is used only while it's a real folder holding codec.db.
"""
import json
import os
from pathlib import Path

_NEW = Path.home() / ".local/share/codec"
_OLD = Path.home() / ".local/share/myOS/codec"

DATA = _OLD if (_OLD.is_dir() and not _OLD.is_symlink()
                and (_OLD / "codec.db").exists()) else _NEW
DB = DATA / "codec.db"
MANIFEST = DATA / "remote-library.json"
ARRIVALS = DATA / "arrivals.json"
# A satellite's key to its hub, given when the hub's owner said ALLOW
# (codec_pairing.py) — owner-only, never in config.json (that's 0644).
HUB_KEY = DATA / "hub-key.json"


def hub_key():
    try:
        return str(json.loads(HUB_KEY.read_text()).get("key") or "")
    except (OSError, ValueError):
        return ""


def hub_headers():
    """Headers for a request to this machine's hub: its key, once paired."""
    k = hub_key()
    return {"X-Codec-Key": k} if k else {}


def hub_hosts():
    """The names/addresses this satellite reaches its hub's private port by
    (syncUrl, hubTailnet) — the only places its key is ever sent."""
    from urllib.parse import urlparse
    cfg = _config()
    out = set()
    for k in ("syncUrl", "hubTailnet"):
        h = urlparse(str(cfg.get(k) or "")).hostname
        if h:
            out.add(h.lower())
    return out


def save_hub_key(key, hub_name, url):
    """Keep the key a hub gave this machine (owner-only)."""
    DATA.mkdir(parents=True, exist_ok=True)
    tmp = HUB_KEY.with_suffix(".tmp")
    tmp.write_text(json.dumps({"key": key, "hub": hub_name, "url": url}))
    os.chmod(tmp, 0o600)
    tmp.replace(HUB_KEY)


def install_hub_auth():
    """Every urllib request THIS script makes to its hub carries the key; no
    other host ever sees it. Call once at start (a satellite's scripts)."""
    import urllib.request
    from urllib.parse import urlparse
    key, hosts = hub_key(), hub_hosts()
    if not key or not hosts:
        return

    class _HubKey(urllib.request.BaseHandler):
        handler_order = 100

        def http_request(self, req):
            if (urlparse(req.full_url).hostname or "").lower() in hosts \
                    and not req.has_header("X-codec-key"):
                req.add_header("X-Codec-Key", key)
            return req
        https_request = http_request

    urllib.request.install_opener(urllib.request.build_opener(_HubKey()))


CFG = Path.home() / ".config/codec/config.json"


def _config():
    try:
        return json.loads(CFG.read_text())
    except (OSError, ValueError):
        return {}


def serve_root():
    """The folder the hub's server (codec-serve) works from: settings.serveRoot.
    A film's address is its path under it. The author's hub serves its /mnt tree; a
    new install serves "/" — every address is the file's own path — and then
    only files inside its media paths (codec_serve.py, _servable)."""
    r = str(_config().get("settings", {}).get("serveRoot") or "/").rstrip("/")
    return r or "/"


def media_roots():
    """The real paths of this machine's media paths (config roots)."""
    out = []
    for r in _config().get("roots") or []:
        p = (r or {}).get("path") if isinstance(r, dict) else None
        if p:
            out.append(os.path.realpath(os.path.expanduser(p)))
    return out


def hub_rel(path):
    """A file on THIS hub as its server's URL path ("/Movies/x.mkv" under
    /mnt, the whole path under "/"), or None: not served here, or this
    machine is a satellite (its own files go through the cast worker)."""
    if not path or (_config().get("syncUrl") or ""):
        return None
    root = serve_root()
    if root == "/":
        real = os.path.realpath(path)
        ok = any(real == m or real.startswith(m.rstrip("/") + "/") for m in media_roots())
        return path if ok else None
    return path[len(root):] if path.startswith(root + "/") else None


def lan_ip(peer=None):
    """This machine's address on the home network. Toward a given device (a
    TV): the interface that reaches it — right when there are two networks.
    Otherwise its real home-network address (codec_hubs.lan_addresses: not
    the tailnet, not a container bridge), and only then the old trick of
    asking the route to a typical router. 127.0.0.1 if there's no network."""
    import socket
    def route_to(host):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect((host, 9))           # no packet is sent; it only picks a route
            return s.getsockname()[0]
        finally:
            s.close()
    if peer:
        try:
            return route_to(str(peer))
        except OSError:
            pass
    try:
        import codec_hubs
        addrs = codec_hubs.lan_addresses()
        if addrs:
            return addrs[0]
    except Exception:
        pass
    try:
        return route_to("192.168.0.1")
    except OSError:
        return "127.0.0.1"


# What to install, by distro family — only names known to be right; anything
# else gets the honest generic line rather than a wrong command.
_PKGS = {
    "yt-dlp": {"arch": "yt-dlp", "fedora": "yt-dlp", "debian": "yt-dlp"},
    "pychromecast": {"arch": "python-pychromecast python-zeroconf",
                     "debian": "python3-pychromecast python3-zeroconf"},
    "mkvmerge": {"arch": "mkvtoolnix-cli", "fedora": "mkvtoolnix", "debian": "mkvtoolnix"},
}
_PIP = {"pychromecast": "pychromecast zeroconf", "yt-dlp": "yt-dlp"}


def distro_family():
    """arch | fedora | debian | suse | "" — from /etc/os-release ID / ID_LIKE."""
    try:
        txt = Path("/etc/os-release").read_text()
    except OSError:
        return ""
    ids = []
    for line in txt.splitlines():
        if line.startswith(("ID=", "ID_LIKE=")):
            ids += line.split("=", 1)[1].strip().strip('"').lower().split()
    for fam in ("arch", "fedora", "debian", "suse"):
        if any(fam in i for i in ids) or (fam == "debian" and "ubuntu" in ids):
            return fam
    return ""


def install_hint(what):
    """How to install `what` on THIS machine (the hint a missing tool shows)."""
    fam = distro_family()
    pkg = _PKGS.get(what, {}).get(fam)
    cmd = {"arch": "sudo pacman -S", "fedora": "sudo dnf install",
           "debian": "sudo apt install", "suse": "sudo zypper install"}.get(fam)
    if pkg and cmd:
        return f"{cmd} {pkg}"
    if what in _PIP:
        return f"install {what} with your package manager (or: pip install --user {_PIP[what]})"
    return f"install {what} with your package manager"


if __name__ == "__main__":
    print(DATA)
