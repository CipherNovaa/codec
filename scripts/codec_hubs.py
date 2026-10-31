#!/usr/bin/env python3
"""codec hubs on the local network — a hub says it's there, a satellite finds it.

A hub whose server is running (SHARE THIS LIBRARY) announces itself over
zeroconf/mDNS as `_codec._tcp`, the way a TV announces `_googlecast._tcp`: its
name and its port, on its home-network addresses only (never the tailnet,
never Docker's bridges). A laptop's first screen lists what it hears
("USE A CODEC HUB ON THIS NETWORK") and asks the one you pick to join
(codec_pairing.py). Saying it's there gives nothing away: a hub that doesn't
trust its network answers only devices it has let in.

    codec_hubs.py --find [seconds]     JSON list of hubs heard (default 3 s)
    codec_hubs.py --join <url> [--name N] [--kind laptop]
                                       ask a hub to join; JSON lines of progress

python-zeroconf is optional: without it a hub just doesn't announce, and a
laptop can still be pointed at a hub's address by hand.
"""
import ipaddress
import json
import socket
import sys
import threading
import time

SERVICE = "_codec._tcp.local."
_SKIP_IFACES = ("docker", "br-", "veth", "virbr", "lxc", "tailscale", "wg", "tun", "zt")


def lan_addresses():
    """This machine's home-network IPv4 addresses (private, not the tailnet's
    100.64/10, not a container bridge)."""
    out = []
    try:
        import ifaddr
        for a in ifaddr.get_adapters():
            if a.nice_name.startswith(_SKIP_IFACES) or a.nice_name == "lo":
                continue
            for i in a.ips:
                if not isinstance(i.ip, str):
                    continue
                ip = ipaddress.ip_address(i.ip)
                if ip.is_private and not ip.is_loopback and \
                        ip not in ipaddress.ip_network("100.64.0.0/10"):
                    out.append(i.ip)
    except Exception:
        pass
    return out


def announce(name_fn, port, version=""):
    """Start announcing this hub, and keep its name current: `name_fn()` is
    re-read every few seconds (Settings ▸ LIBRARY ▸ HUB NAME), and a new name
    is re-announced in place — no server restart, no cast interrupted.
    Returns the Zeroconf handle (keep it alive), or None without
    python-zeroconf or a home-network address. All the slow parts (probing a
    name) run on their own thread."""
    try:
        from zeroconf import ServiceInfo, Zeroconf
    except ImportError:
        return None
    addrs = lan_addresses()
    if not addrs:
        return None
    zc = Zeroconf()
    host = socket.gethostname().split(".")[0]

    def info_for(name):
        return ServiceInfo(
            SERVICE, f"{name}.{SERVICE}",
            addresses=[socket.inet_aton(a) for a in addrs], port=port,
            properties={"name": name, "v": version or "1"},
            server=f"{host}.local.")

    def run():
        current, info = None, None
        while True:
            try:
                name = name_fn()
            except Exception:
                name = current or host
            if name and name != current:
                try:
                    if info is not None:
                        zc.unregister_service(info)
                    info = info_for(name)
                    zc.register_service(info, allow_name_change=True)
                    current = name
                    print(f"codec-serve: announced as '{name}' on {', '.join(addrs)}", flush=True)
                except Exception as e:
                    print(f"codec-serve: not announced ({e})", flush=True)
            time.sleep(5)
    threading.Thread(target=run, daemon=True).start()
    return zc


def find(seconds=3.0):
    """Hubs heard within `seconds`: [{name, host, port, url}]."""
    try:
        from zeroconf import ServiceBrowser, Zeroconf
    except ImportError:
        return []
    zc = Zeroconf()
    found = {}

    class Listener:
        def add_service(self, z, type_, name):
            info = z.get_service_info(type_, name, timeout=1500)
            if not info:
                return
            addrs = [a for a in info.parsed_addresses() if ":" not in a]
            if not addrs:
                return
            props = {k.decode(): (v.decode() if isinstance(v, bytes) else v)
                     for k, v in (info.properties or {}).items()}
            label = props.get("name") or name.split(".")[0]
            found[name] = {"name": label, "host": addrs[0], "port": info.port,
                           "url": f"http://{addrs[0]}:{info.port}"}

        def update_service(self, z, type_, name):
            self.add_service(z, type_, name)

        def remove_service(self, z, type_, name):
            found.pop(name, None)

    ServiceBrowser(zc, SERVICE, Listener())
    time.sleep(max(0.5, float(seconds)))
    zc.close()
    return sorted(found.values(), key=lambda h: h["name"].lower())


def join(url, name, kind):
    """Ask the hub at `url` to let this machine in, and wait for its answer
    (someone presses ALLOW on the hub's screen). Prints one JSON line per step
    — {"state": "asking" | "waiting" | "allowed" | "denied" | "expired" |
    "error", "hub": …} — for the app to show; on "allowed" the key is kept
    (codec_paths.save_hub_key, owner-only) and never printed."""
    import urllib.request
    import codec_paths

    def say(**kw):
        print(json.dumps(kw), flush=True)

    def call(path, body=None, timeout=10):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url.rstrip("/") + path, data=data,
                                     headers={"Content-Type": "application/json"},
                                     method="POST" if data is not None else "GET")
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read() or b"{}")

    try:
        hello = call("/pair/hello")
        hub = hello.get("hub") or url
        say(state="asking", hub=hub)
        me = "codec-" + socket.gethostname().split(".")[0].lower()
        r = call("/pair/request", {"id": me, "name": name or socket.gethostname(), "kind": kind})
        rid = r.get("request")
        if not rid:
            say(state="error", hub=hub, why="the hub has too many requests waiting")
            return 1
        say(state="waiting", hub=hub)
        while True:
            w = call(f"/pair/wait?r={rid}&t=25", timeout=35)
            st = w.get("state")
            if st == "pending":
                continue
            if st == "allowed" and w.get("key"):
                codec_paths.save_hub_key(w["key"], w.get("hub") or hub, url.rstrip("/"))
                say(state="allowed", hub=w.get("hub") or hub)
                return 0
            say(state=st or "error", hub=hub)
            return 1
    except Exception as e:
        say(state="error", hub=url, why=str(e)[:120])
        return 1


if __name__ == "__main__":
    if "--join" in sys.argv:
        i = sys.argv.index("--join")
        def opt(flag, default=""):
            return sys.argv[sys.argv.index(flag) + 1] if flag in sys.argv else default
        sys.exit(join(sys.argv[i + 1], opt("--name"), opt("--kind", "laptop")))
    if "--find" in sys.argv:
        i = sys.argv.index("--find")
        secs = float(sys.argv[i + 1]) if len(sys.argv) > i + 1 else 3.0
        print(json.dumps(find(secs)))
    else:
        print(json.dumps({"addresses": lan_addresses()}))
