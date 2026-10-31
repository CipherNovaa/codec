#!/usr/bin/env python3
"""codec navigation helper.

Root problem it solves: Hyprland runs `follow_mouse = 1`, so focus follows the
mouse. Any ydotool keystroke lands on whatever window the CURSOR is over — which
is why keys kept hitting the terminal/chooser. Fix: warp the mouse onto codec's
window FIRST (focus follows it), THEN send keys, and never move the mouse away.

Usage:  python3 nav.py <tok> <tok> ...
Tokens: enter j k h l i esc up down left right p w c slash space  waitN (sleep N s)
        shot:/abs/path.png   (grim -g the codec window region)
Example: python3 nav.py enter wait9 j j shot:/tmp/cw.png
"""
import json
import subprocess
import sys
import time

KEYS = {"enter": 28, "space": 57, "j": 36, "k": 37, "h": 35, "l": 38, "i": 23,
        "esc": 1, "up": 103, "down": 108, "left": 105, "right": 106, "p": 25,
        "w": 17, "c": 46, "slash": 53, "q": 16, "x": 45, "g": 34}


def codec_client():
    """Largest codec window as the full client dict (or None)."""
    cs = json.loads(subprocess.check_output(["hyprctl", "-j", "clients"]))
    best = None
    for c in cs:
        if c.get("class", "").lower() == "codec":
            w, h = c["size"]
            if best is None or w * h > best["size"][0] * best["size"][1]:
                best = c
    return best


def codec_geo():
    c = codec_client()
    return (c["at"][0], c["at"][1], c["size"][0], c["size"][1]) if c else None


def prep():
    """Focus codec by address + make it fullscreen so a mouse warp lands on it
    (it launches small/tiled behind other windows on the CRT)."""
    c = codec_client()
    if not c:
        return None
    subprocess.run(["hyprctl", "dispatch", "focuswindow", "address:" + c["address"]],
                   stdout=subprocess.DEVNULL)
    time.sleep(0.15)
    if not c.get("fullscreen"):
        subprocess.run(["hyprctl", "dispatch", "fullscreen", "1"], stdout=subprocess.DEVNULL)
        time.sleep(0.2)
    return codec_geo()


def warp(x, y):
    subprocess.run(["ydotool", "mousemove", "-a", "-x", str(int(x)), "-y", str(int(y))])
    time.sleep(0.15)


def key(code):
    subprocess.run(["ydotool", "key", "%d:1" % code, "%d:0" % code])
    time.sleep(0.12)


def main():
    geo = prep()
    if not geo:
        print("no codec window", file=sys.stderr)
        return 1
    x, y, w, h = geo
    # Warp to the UPPER-CENTRE (avoids landing on the wheel/continue MouseAreas
    # and triggering hover-driven zone changes). This gives codec focus.
    warp(x + w // 2, y + h // 12)
    time.sleep(0.2)
    active = json.loads(subprocess.check_output(["hyprctl", "-j", "activewindow"]))
    print("focused:", active.get("class"), "| codec geo:", geo)

    for tok in sys.argv[1:]:
        if tok.startswith("wait"):
            time.sleep(float(tok[4:] or 1))
        elif tok.startswith("shot:"):
            g = codec_geo() or geo
            subprocess.run(["grim", "-g", "%d,%d %dx%d" % g, tok[5:]])
            print("shot", tok[5:], "of", g)
        elif tok in KEYS:
            # keep focus: re-assert the warp only if the mouse might have drifted
            key(KEYS[tok])
        else:
            print("unknown token:", tok, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
