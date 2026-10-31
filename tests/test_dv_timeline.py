#!/usr/bin/env python3
"""The Dolby Vision lane's manifest tail (codec_serve.py: _dv_extend_timeline,
dv_dash_manifest, dv_write_profile / dv_profile_durs), offline.

The TV fetches its manifest once, at cast start, when the muxer has written one
to three GOPs; everything after is the hub's fill, and the TV plays BY that
timeline for the rest of the film. A fill averaged from those first GOPs ran
0.4% short on Pirates of the Caribbean and put the TV's clock 31 s off the
media by the second hour (2026-10-12: the "buffers at the end of the film"
bug). Pinned here: the fill is sized to the film, never over-counts, and a
title that has been cast before gets its exact timeline back.

    python3 tests/test_dv_timeline.py
"""
import json, os, pathlib, re, sys, tempfile

os.environ["HOME"] = tempfile.mkdtemp(prefix="dvtl-")
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "scripts"))
import codec_serve as cs

fails = 0


def check(name, got, want):
    global fails
    ok = got == want
    fails += 0 if ok else 1
    print(f"  {'ok ' if ok else 'FAIL'} {name}: {got!r}" + ("" if ok else f" (want {want!r})"))


def mpd(video, audio):
    """ffmpeg-shaped manifest with these produced entries (ticks)."""
    def tl(ds):
        out = [f'<S t="0" d="{ds[0]}" />'] + [f'<S d="{d}" />' for d in ds[1:]]
        return "".join(out)
    return (f'<MPD type="dynamic"><Period>'
            f'<AdaptationSet contentType="video"><Representation id="0" codecs="">'
            f'<SegmentTemplate timescale="16000" initialization="v$RepresentationID$/init.mp4" '
            f'media="v$RepresentationID$/seg$Number$.m4s" startNumber="1">'
            f'<SegmentTimeline>{tl(video)}</SegmentTimeline></SegmentTemplate></Representation></AdaptationSet>'
            f'<AdaptationSet contentType="audio"><Representation id="1" codecs="mp4a.40.2">'
            f'<SegmentTemplate timescale="48000" initialization="v$RepresentationID$/init.mp4" '
            f'media="v$RepresentationID$/seg$Number$.m4s" startNumber="1">'
            f'<SegmentTimeline>{tl(audio)}</SegmentTimeline></SegmentTemplate></Representation></AdaptationSet>'
            f'</Period></MPD>')


def ticks(man, ctype):
    return cs._mpd_timeline_ticks(man, ctype)


# A film like tonight's: 859 GOPs, 240 frames nominal with the real 238..243
# scatter, a 0.7 s runt at the end; the first three GOPs run short.
import random
random.seed(7)
F = 16000 * 1001 // 24000          # ticks per frame at 23.976 (667.3 -> integer maths below)
def gop_ticks(frames):
    return round(frames * 16000 * 1001 / 24000)
# a clean-GOP encode: 240 nominal, scene cuts and open-GOP slack scattering
# the length symmetrically (the real film: 271×240, 104×239, 97×241, 56×243, 54×238, 53×242)
frames = [240, 240, 237] + ([239, 241, 240, 238, 242, 240] * 143)[:855] + [17]   # mean exactly 240
real_v = [gop_ticks(f) for f in frames]
real_a = [round(f * 48000 * 1001 / 24000) for f in frames]
full_dur = sum(real_v) / 16000
nominal = 10.01

print("the even fill, sized to the film (a title's first cast)")
early = mpd(real_v[:3], real_a[:3])
man = cs.dv_dash_manifest(early, "k", full_dur, 0.0, {}, pieces=1, gop=nominal, src="")
v, a = ticks(man, "video"), ticks(man, "audio")
check("video count never exceeds the real count", len(v) <= len(real_v), True)
check("audio count never exceeds the real count", len(a) <= len(real_a), True)
check("video total is the film", abs(sum(v) / 16000 - full_dur) < 0.001, True)
check("audio total is the film", abs(sum(a) / 48000 - full_dur) < 0.001, True)
cum_v = [sum(v[:i]) / 16000 for i in range(len(v) + 1)]
cum_r = [sum(real_v[:i]) / 16000 for i in range(len(real_v) + 1)]
worst = max(abs(cum_v[i] - cum_r[i]) for i in range(len(v)))
check("worst drift over the film under 2 s", worst < 2.0, True)
check("drift at GOP 743 under 1.5 s", abs(cum_v[743] - cum_r[743]) < 1.5, True)
old = cs.dv_dash_manifest(early, "k", full_dur, 0.0, {}, pieces=1)
ov = ticks(old, "video")
cum_o = [sum(ov[:i]) / 16000 for i in range(len(ov) + 1)]
check("(the old fill drifted past 10 s)", abs(cum_o[min(743, len(ov))] - cum_r[743]) > 10, True)
check("(the old fill over-counted)", len(ov) > len(real_v), True)

print("the exact profile (every later cast)")
cs.DV_PROFILE_DIR = pathlib.Path(tempfile.mkdtemp(prefix="dvprof-"))
spool = pathlib.Path(tempfile.mkdtemp(prefix="spool-"))
(spool / "v0").mkdir()
for i in range(1, len(real_v) + 1):
    (spool / "v0" / f"seg{i}.m4s").write_bytes(b"\0" * 1000)
(spool / "manifest.mpd").write_text(mpd(real_v, real_a))
src = spool / "film.mkv"; src.write_bytes(b"\0" * 64)
cs.dv_write_profile(str(src), nominal, spool / "v0", 0.0)
prof = json.loads(next(cs.DV_PROFILE_DIR.glob("*.json")).read_text())
check("profile keeps the durations", len(prof.get("durs_v", [])), len(real_v))
check("profile keeps the GOP", prof.get("gop"), nominal)
check("the reader hands them back", cs.dv_profile_durs(str(src), nominal) is not None, True)
check("…but not at another GOP", cs.dv_profile_durs(str(src), 8.0), None)
man2 = cs.dv_dash_manifest(early, "k", full_dur, 0.0, {}, pieces=1, gop=nominal, src=str(src))
check("video timeline exact", ticks(man2, "video"), real_v)
check("audio timeline exact", ticks(man2, "audio"), real_a)
man3 = cs.dv_dash_manifest(early, "k", full_dur, 0.0, {}, pieces=5, gop=nominal, src=str(src))
check("pieces split the exact GOPs", len(ticks(man3, "video")), len(real_v) * 5)
check("…to the same total", sum(ticks(man3, "video")), sum(real_v))
# a resume cast's spool starts mid-film: the profile can't index it, the fill does
man4 = cs.dv_dash_manifest(mpd(real_v[400:403], real_a[400:403]), "k", full_dur - cum_r[400], cum_r[400], {}, pieces=1, gop=nominal, src=str(src))
head4 = {}
man4 = cs.dv_dash_manifest(mpd(real_v[400:403], real_a[400:403]), "k", full_dur - cum_r[400], cum_r[400], head4, pieces=1, gop=nominal, src=str(src))
v4 = ticks(man4, "video")[head4.get("v0", 0):]     # past the placeholder head
check("a resume gets a sized fill, never over-counting", 0 < len(v4) <= len(real_v) - 400, True)
# a partial spool writes no durations
cs.dv_write_profile(str(src), nominal, spool / "v0", 1234.0)
prof = json.loads(next(cs.DV_PROFILE_DIR.glob("*.json")).read_text())
check("a resume's spool keeps bins only", "durs_v" in prof, False)

print(f"\n{'ALL OK' if not fails else str(fails) + ' FAILED'}")
sys.exit(1 if fails else 0)
