#!/usr/bin/env python3
"""Clear clearlogos that aren't real transparent art.

A clearlogo MUST be an RGBA/grayscale-alpha PNG floated on transparency. A logo
that arrives with NO alpha channel renders as an opaque slab (e.g. red text on a
white box) over the spotlight backdrop — the Mr. Robot glitch. Rather than patch
one title, this sweeps every clearlogo and clears the DB pointer for any that has
no alpha channel, so the UI falls back to the clean text title until a proper
transparent logo is fetched. Idempotent; safe to run any time.

  --dry   report only, change nothing
"""
import os
import sqlite3
import subprocess
import sys
import codec_paths  # where codec's data lives (~/.local/share/codec)

DB = str(codec_paths.DB)


def has_alpha(path):
    """True iff the image is USABLE transparent art — a real alpha channel that
    actually carries transparency. %[channels] ('srgba'/'graya') proves the
    channel exists; %[opaque]!='True' proves it isn't a fully-opaque plate (RGBA
    white text on an opaque slab — the white-box glitch). Presence alone is not
    enough."""
    if not path or not os.path.exists(path):
        return True  # missing file is handled elsewhere; don't touch the row
    try:
        out = subprocess.run(["identify", "-format", "%[channels]|%[opaque]", path],
                            capture_output=True, text=True, timeout=15).stdout.strip()
        chan, _, opaque = out.partition("|")
        if not chan.split()[0].lower().endswith("a"):
            return False
        return opaque.strip().lower() != "true"
    except Exception as e:
        print(f"  has_alpha: identify failed ({e}) — keeping row unchecked",
              file=sys.stderr)
        return True  # never clear on a probe failure — fail safe


def main():
    dry = "--dry" in sys.argv
    db = sqlite3.connect(DB)
    rows = db.execute(
        "SELECT path, title, clearlogo FROM metadata"
        " WHERE clearlogo IS NOT NULL AND clearlogo!=''"
    ).fetchall()
    bad = [(p, t, l) for p, t, l in rows if not has_alpha(l)]
    for p, t, l in bad:
        print("opaque logo -> clearing: %s" % t)
        if not dry:
            db.execute(
                "UPDATE metadata SET clearlogo='', clearlogo_url='' WHERE path=?",
                (p,))
    if not dry:
        db.commit()
    print("%s %d/%d clearlogos had no alpha channel"
          % ("would clear" if dry else "cleared", len(bad), len(rows)))


if __name__ == "__main__":
    main()
