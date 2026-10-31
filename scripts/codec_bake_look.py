#!/usr/bin/env python3
"""Bake the look from this machine's codec config into the build.

codec ships with ONE look: the garage editor's settings as the author tuned them.
They live in ~/.config/codec/config.json (device-local, never in git), so a new
machine used to start from the code's older defaults. This copies the look keys
— and only those: no roots, hubs, keys or tokens — into assets/look/look.json,
which the app reads for any key a person's own config doesn't set
(AppController::loadSettings). Re-run it after tuning in the garage editor,
rebuild, commit.

    scripts/codec_bake_look.py            # write assets/look/look.json
    scripts/codec_bake_look.py --diff     # show what would change
"""
import json
import sys
from pathlib import Path

CONFIG = Path.home() / ".config/codec/config.json"
OUT = Path(__file__).resolve().parent.parent / "assets/look/look.json"

# The keys that make codec LOOK and SOUND like codec. Behaviour (autoplay,
# attract timing, HDR, audio device) keeps the code's defaults.
LOOK_KEYS = [
    "mechUiSel",        # HOME: plates, wheel, card, motion (garage editor)
    "statsUiSel",       # STATS cockpit (its own garage editor)
    "mechEditorSys",    # the editor's system look: accent, title face, keytips
    "iconTopSel",       # the home wheel's icons
    "iconBotSel",
    "glassLevel",       # menu glass
    "mechPalette",
    "redactionStyle",   # attract mode's DECODING bars
    "osdTitleLogo",
    "subtitleScale",    # local captions
    "localCaptionColor",
    "uiSounds",
    "uiSoundPack",
    "uiSoundLevel",
]


def main():
    settings = json.loads(CONFIG.read_text()).get("settings", {})
    look = {k: settings[k] for k in LOOK_KEYS if k in settings}
    missing = [k for k in LOOK_KEYS if k not in settings]
    doc = {"_about": "codec's shipped look - scripts/codec_bake_look.py writes this; "
                     "read by AppController::loadSettings for keys a config doesn't set",
           "settings": look}
    text = json.dumps(doc, indent=2, ensure_ascii=False, sort_keys=False) + "\n"
    old = OUT.read_text() if OUT.exists() else ""
    if "--diff" in sys.argv:
        before = json.loads(old).get("settings", {}) if old else {}
        for k in LOOK_KEYS:
            if before.get(k) != look.get(k):
                print(f"  {k}: changed")
        return
    if text == old:
        print("look.json already matches this config")
        return
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text)
    print(f"wrote {OUT} ({len(look)} keys)" + (f"; not set here: {', '.join(missing)}" if missing else ""))


if __name__ == "__main__":
    main()
