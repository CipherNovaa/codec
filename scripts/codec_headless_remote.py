#!/usr/bin/env python3
"""Headless cast that the physical OFA remote can actually drive (thread C).

`codec_headless_cast.py` fires a raw LOAD and exits, so nothing drains the hub's
`/rc` queue and the remote's keypresses pile up unconsumed — the remote is dead on
a headless cast. This instead runs the REAL cast worker (`codec_cast.py`, where
every op already lives), feeds it the load, then polls `/rc` and maps each remote
op to a worker op — computing the cycle/toggle from the tracks the worker reports,
exactly what the app's AppController::rcPoll does, minus the GUI.

Because it's the real worker, the receiver's action toasts (SUBTITLES/AUDIO/ZOOM)
fire here too — the thing a fire-and-forget headless cast could never show.

Usage: codec_headless_remote.py <file> [--start S] [--hub URL] [--device UUID]
A remote STOP, Ctrl-C, or the worker exiting quits the receiver cleanly.
"""
import argparse, json, os, socket, subprocess, sys, threading, time
import urllib.request, urllib.parse

HERE = os.path.dirname(os.path.realpath(__file__))
WORKER = os.path.join(HERE, "codec_cast.py")
SERVE_ROOT = "/mnt"


def lan_hub(explicit):
    """Hub base for the /rc queue — the receiver POSTs keys to the hub it loaded
    from, and on the hub machine that's this box's LAN address (same serve either
    way, since _RC lives in-process)."""
    if explicit:
        return explicit.rstrip("/")
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
    except Exception:
        ip = "127.0.0.1"
    finally:
        s.close()
    return f"http://{ip}:8200"


def resolve(p):
    """A hub /mnt file the worker can turn into a lane (mirrors codec_headless_cast)."""
    ap = os.path.abspath(p)
    if not ap.startswith(SERVE_ROOT + "/") or not os.path.isfile(ap):
        sys.exit(f"not a hub file under {SERVE_ROOT}/: {ap}")
    return ap


class Bridge:
    def __init__(self, args):
        self.hub = lan_hub(args.hub)
        self.file = resolve(args.file)
        self.start = args.start
        self.dev_id = args.device          # None -> first discovered
        # live cast state, kept current from the worker's "tracks" events
        self.audio, self.subs = [], []
        self.aidx, self.sub, self.mode = 0, -1, "fit"
        self.last_sub_on = -1              # remember a sub so a toggle can turn it back on
        self.opid = 1000
        self.stop = threading.Event()
        self.proc = None

    # -- worker channel ----------------------------------------------------
    def send(self, op):
        self.opid += 1
        op = {"id": self.opid, **op}
        try:
            self.proc.stdin.write(json.dumps(op) + "\n")
            self.proc.stdin.flush()
        except Exception:
            pass

    def _reader(self):
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
            except Exception:
                continue
            ev = e.get("event")
            if ev == "device" and not self.dev_id:
                self.dev_id = e.get("id")
            elif ev == "tracks":
                self.audio = e.get("audio") or self.audio
                self.subs = e.get("subs") or self.subs
                self.aidx = e.get("aidx", self.aidx)
                self.sub = e.get("sub", self.sub)
                self.mode = e.get("mode", self.mode)
                if isinstance(self.sub, int) and self.sub >= 0:
                    self.last_sub_on = self.sub
            elif ev == "cast_error":
                print("cast: " + str(e.get("error", "")), file=sys.stderr)
        self.stop.set()               # worker stdout closed -> we're done

    # -- remote op -> worker op (mirrors AppController::rcPoll) -------------
    def handle(self, op):
        if op == "audio":                                   # cycle audio track
            if self.audio:
                self.send({"op": "set_audio", "index": (self.aidx + 1) % len(self.audio)})
        elif op == "sub":                                   # toggle subtitles on/off
            if isinstance(self.sub, int) and self.sub >= 0:
                self.send({"op": "set_sub", "index": -1})
            else:
                idx = self.last_sub_on if self.last_sub_on >= 0 else (0 if self.subs else -1)
                if idx >= 0:
                    self.send({"op": "set_sub", "index": idx})
        elif op == "sub_cycle":                             # off -> 0 -> 1 -> ... -> off
            if self.subs:
                nxt = (self.sub if isinstance(self.sub, int) else -1) + 1
                self.send({"op": "set_sub", "index": nxt if nxt < len(self.subs) else -1})
        elif op == "zoom":                                  # cycle screen mode
            self.send({"op": "screen_mode", "mode": "zoom" if self.mode != "zoom" else "fit"})
        elif op == "stop":
            self.send({"op": "stop"})
            self.stop.set()
        # chan_next/chan_prev: no queue on a headless cast -> ignore
        # seek: a solo-cast receiver seeks itself locally -> ignore (as rcPoll does)

    def poll_rc(self):
        while not self.dev_id and not self.stop.is_set():
            time.sleep(0.2)
        if not self.dev_id:
            return
        url = f"{self.hub}/rc?dev=" + urllib.parse.quote(self.dev_id, safe="")
        while not self.stop.is_set():
            try:
                ops = json.loads(urllib.request.urlopen(url, timeout=2).read()).get("ops") or []
                for it in ops:
                    self.handle(str(it.get("op", "")))
            except Exception:
                pass
            time.sleep(0.3)

    # -- lifecycle ---------------------------------------------------------
    def run(self):
        self.proc = subprocess.Popen(["python3", WORKER], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, text=True, bufsize=1)
        threading.Thread(target=self._reader, daemon=True).start()
        t0 = time.time()                       # wait for ready + a device
        while not self.dev_id and time.time() - t0 < 10 and not self.stop.is_set():
            time.sleep(0.2)
        if not self.dev_id:
            print("no cast device found", file=sys.stderr)
            return self.cleanup(1)
        self.send({"op": "load", "device": self.dev_id, "uri": self.file,
                   "title": os.path.splitext(os.path.basename(self.file))[0],
                   "position": self.start})
        print(f"cast -> {self.dev_id}; remote bridge live (polling {self.hub}/rc). Ctrl-C to stop.",
              flush=True)
        threading.Thread(target=self.poll_rc, daemon=True).start()
        try:
            while not self.stop.is_set() and self.proc.poll() is None:
                time.sleep(0.5)
        except KeyboardInterrupt:
            self.send({"op": "stop"})
            time.sleep(1.5)
        return self.cleanup(0)

    def cleanup(self, code):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        time.sleep(0.5)
        try:
            self.proc.terminate()
        except Exception:
            pass
        return code


def main():
    ap = argparse.ArgumentParser(description="Headless cast with the physical remote working.")
    ap.add_argument("file", help="a hub /mnt media file")
    ap.add_argument("--start", type=float, default=0.0, help="start position (seconds)")
    ap.add_argument("--hub", default="", help="hub base URL (default: this box's LAN :8200)")
    ap.add_argument("--device", default="", help="cast device uuid (default: first discovered)")
    a = ap.parse_args()
    a.device = a.device or None
    sys.exit(Bridge(a).run())


if __name__ == "__main__":
    main()
