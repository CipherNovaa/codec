#!/usr/bin/env python3
"""Subtitle timing (scripts/codec_subsync.py): the verdicts, offline.

ffsubsync itself is not run here — its three answers are fed in as the log
lines it prints, and the module's judgement over them is what is pinned:
a confident fit is applied, a weak or failed one leaves the file alone, a
tiny correction isn't worth a write, an absurd one is the wrong cut. The
swap is exercised end to end with a stand-in "ffsubsync" so the raw copy,
the atomic replace, the record and its idempotence are real.

    python3 tests/test_subsync.py
"""
import os, pathlib, stat, sys, tempfile

os.environ["HOME"] = tempfile.mkdtemp(prefix="subsync-")
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "scripts"))
import codec_subsync as ss

LOG = """[10:58:06] INFO     extracting speech segments from reference   ffsubsync.py:734
           INFO     extracting speech segments from subtitles   ffsubsync.py:192
           INFO     score: {score}                            ffsubsync.py:255
           INFO     offset seconds: {offset}                      ffsubsync.py:256
           INFO     framerate scale factor: {scale}               ffsubsync.py:257
"""
fails = 0


def check(name, got, want):
    global fails
    ok = got == want
    fails += 0 if ok else 1
    print(f"  {'ok ' if ok else 'FAIL'} {name}: {got!r}" + ("" if ok else f" (want {want!r})"))


def log(score, offset, scale):
    return LOG.format(score=score, offset=offset, scale=scale)


print("parse")
m = ss.parse(log("63548.000", "-0.520", "1.000"))
check("ran", m["ran"], True)
check("score", m["score"], 63548.0)
check("offset", m["offset"], -0.52)
check("scale", m["scale"], 1.0)
check("crash is no verdict", ss.parse("Traceback (most recent call last)…", 1)["ran"], False)
check("non-zero exit is no verdict", ss.parse(log("1", "0", "1"), 2)["ran"], False)
check("missing line is no verdict", ss.parse("INFO score: 5\n")["ran"], False)

print("verdict")
dur = 1516.0
check("a confident half-second is applied",
      ss.verdict(ss.parse(log("63548", "-0.520", "1.000")), dur), ("apply", "re-timed"))
check("PAL stretch is applied",
      ss.verdict(ss.parse(log("63543", "-2.440", "0.959")), dur), ("apply", "re-timed"))
check("a pure ratio with no shift is applied",
      ss.verdict(ss.parse(log("63543", "0.02", "0.959")), dur), ("apply", "re-timed"))
check("in sync is kept",
      ss.verdict(ss.parse(log("63548", "0.080", "1.001")), dur), ("keep", "in sync"))
check("a negative score fails",
      ss.verdict(ss.parse(log("-10394", "25.070", "0.960")), dur), ("failed", "no fit"))
check("a weak fit fails",
      ss.verdict(ss.parse(log("900", "-3.0", "1.000")), dur), ("failed", "weak fit"))
check("unknown duration trusts the sign",
      ss.verdict(ss.parse(log("900", "-3.0", "1.000")), 0), ("apply", "re-timed"))
check("a 40 s shift is the wrong cut",
      ss.verdict(ss.parse(log("217237", "-40.0", "1.000")), 6420), ("suspect", "wrong cut?"))
check("no verdict fails", ss.verdict({"ran": False}, dur), ("failed", "no verdict"))

print("describe")
check("late", ss.describe({"verdict": "apply", "offset": -9.74, "scale": 1.001}), "−9.7 S")
check("stretched + shifted", ss.describe({"verdict": "apply", "offset": -2.44, "scale": 0.959}),
      "−2.4 S · 0.959 ×")
check("early", ss.describe({"verdict": "apply", "offset": 0.5, "scale": 1.0}), "+0.5 S")
check("kept", ss.describe({"verdict": "keep"}), "IN SYNC")
check("suspect", ss.describe({"verdict": "suspect"}), "WRONG CUT?")

print("sync (stand-in tool)")
work = pathlib.Path(tempfile.mkdtemp(prefix="subsync-work-"))
video = work / "film.mkv"
video.write_bytes(b"\x1a\x45\xdf\xa3" + b"\0" * 64)
sub = work / "film.en.srt"
RAW = "1\n00:00:03,504 --> 00:00:04,879\n[DOOR OPENS]\n"
sub.write_text(RAW)
fake = work / "ffsubsync"
# a stand-in: writes a re-timed file where asked and prints the verdict lines
fake.write_text("#!/bin/sh\n"
                "out=''; while [ $# -gt 0 ]; do [ \"$1\" = -o ] && out=$2; shift; done\n"
                # like the real tool: the output's extension names its format\n
                "case \"$out\" in *.srt|*.ass|*.ssa) ;; *) echo 'INFO score: 1'; exit 0;; esac\n"
                "printf '1\\n00:00:02,984 --> 00:00:04,359\\n[DOOR OPENS]\\n' > \"$out\"\n"
                "echo 'INFO score: 63548.000'; echo 'INFO offset seconds: -0.520';"
                " echo 'INFO framerate scale factor: 1.000'\n")
fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
ss.FFS = fake
ss._FF8 = work / "nowhere"
ss.SYNC_DIR = work / "sync"
ss.FFPROBE = "/bin/false"
rec = ss.sync(video, sub, dur=1516.0)
check("applied", rec["applied"], True)
check("verdict", rec["verdict"], "apply")
check("file re-timed", "00:00:02,984" in sub.read_text(), True)
check("raw kept", pathlib.Path(rec["raw"]).read_text(), RAW)
check("no tmp left", sorted(p.name for p in work.iterdir() if p.name.startswith(".")), [])
check("record kept", ss.read_record(sub)["offset"], -0.52)
again = ss.sync(video, sub, dur=1516.0)
check("second call is the kept record", again.get("cached"), True)
forced = ss.sync(video, sub, dur=1516.0, force=True)
check("force re-measures", forced.get("cached"), None)
# a tool that fails leaves the file alone
fake.write_text("#!/bin/sh\necho 'Traceback'; exit 1\n")
sub.write_text(RAW)
rec = ss.sync(video, sub, dur=1516.0, force=True)
check("failure keeps the file", sub.read_text(), RAW)
check("failure verdict", rec["verdict"], "failed")
check("failure carries the tail", "Traceback" in rec.get("error", ""), True)
check("an unknown extension is skipped", ss.sync(video, work / "x.txt")["verdict"], "skipped")

print("the subtitle's encoding, named for ffsubsync (it guessed VISCII once)")
_ed = pathlib.Path(tempfile.mkdtemp(prefix="enc-"))
(_ed / "a.srt").write_bytes("1\r\n00:00:01,000 --> 00:00:02,000\r\nCaf\xe9 cr\xe8me\r\n".encode("cp1252"))
(_ed / "b.srt").write_bytes("1\n00:00:01,000 --> 00:00:02,000\nCaf\xe9\n".encode("utf-16"))
(_ed / "c.srt").write_bytes("1\n00:00:01,000 --> 00:00:02,000\nCaf\xe9\n".encode("utf-8"))
check("cp1252", ss.sub_encoding(_ed / "a.srt"), "cp1252")
check("utf-16 by its mark", ss.sub_encoding(_ed / "b.srt"), "utf-16")
check("utf-8", ss.sub_encoding(_ed / "c.srt"), "utf-8-sig")

print(f"\n{'ALL OK' if not fails else str(fails) + ' FAILED'}")
sys.exit(1 if fails else 0)
