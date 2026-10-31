#!/usr/bin/env python3
"""Your library, on any screen — the link you bookmark, and the one you lend.

    codec_browse.py            # show the live link (does NOT rotate it)
    codec_browse.py --home     # your own phone's app: alive as long as you use it
    codec_browse.py --home --qr   # ...as a QR to scan, and copied to the clipboard
    codec_browse.py 4          # a 4-hour link
    codec_browse.py --new 4    # rotate to a fresh 4-hour link
    codec_browse.py --off      # revoke immediately

Two different jobs were sharing one 12-hour default, badly. Bookmarking your
own library wants a link that is still there next week; handing a phone to
someone at a party wants one that dies on its own. So: `--home` stays alive as
long as you keep using it (60 days untouched and it lapses — the hub enforces a
finite life since the August audit, which had silently turned "never" into one
week and killed the bookmarked phone app), a plain number expires, and running
it with no arguments just shows you what's live instead of quietly rotating the
link you already saved somewhere.

Revoking is instant either way, and that — not the clock — is the control that
matters. This link is NOT a party invite: it can list and stream your whole
library, so it's yours, not something to paste in a group chat.
"""
import json
import sys
import urllib.request

HUB = "http://127.0.0.1:8200"


def call(path, body):
    req = urllib.request.Request(HUB + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r)


def main():
    args = sys.argv[1:]
    if "--off" in args:
        call("/browse/stop", {})
        print("browse link revoked.")
        return 0
    home = "--home" in args or "--forever" in args
    fresh = "--new" in args
    hours = None
    for a in args:
        if a.startswith("-"):
            continue
        try:
            hours = int(a)
        except ValueError:
            pass
    if not home and hours is None and not fresh:
        # just SHOW what's live — this used to mint (12 h) and quietly cut the
        # phone app's 60-day link down to 12 hours
        d = call("/browse/show", {})
        if not d.get("live"):
            print("no live browse link — `--home` makes your phone app's link")
            return 0
    else:
        if hours is not None and not fresh and not home:
            cur = call("/browse/show", {})
            if cur.get("live") and cur.get("home_idle_days"):
                print("your phone app's link is live, and lending it would hand "
                      "out that same link.\nUse --new to mint a separate one "
                      "(the phone app then needs re-adding).", file=sys.stderr)
                return 1
        d = call("/browse/start", {"hours": hours or 12, "new": fresh, "home": home})
    url = d.get("url") or ""
    if not url:
        print("minted, but Tailscale Funnel isn't up — the link has no public "
              "address yet. Start Funnel, then run this again.", file=sys.stderr)
        return 1
    got = d.get("hours", hours)
    if "--qr" in args:
        import shutil, subprocess
        if shutil.which("qrencode"):
            subprocess.run(["qrencode", "-t", "ANSIUTF8", "-m", "2", url])
        if shutil.which("wl-copy"):
            subprocess.run(["wl-copy"], input=url.encode())
            print("  (copied to the clipboard)")
    print(f"\n  {url}\n")
    if d.get("home_idle_days"):
        print(f"  your phone app · stays alive while you use it "
              f"({d['home_idle_days']} days untouched and it lapses) · revoke with --off")
        print("  on the phone: open it in CHROME (casting needs Chrome), then "
              "⋮ → Add to Home screen / Install app")
    else:
        print(f"  valid {got}h · revoke any time with --off")
    if d.get("kept"):
        print("  (same link as before — use --new to rotate it)")
    elif not fresh:
        print("  (a NEW link — the old one had lapsed; re-add it to the phone)")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except urllib.error.URLError as e:
        print(f"hub not reachable at {HUB}: {e}", file=sys.stderr)
        raise SystemExit(1)
