#!/usr/bin/env python3
"""The subtitle finder's judgement (codec_serve.py), offline.

What a provider hands back is judged before it is saved: the right episode,
a timeline the film's own length doesn't refute, text that reads clean —
and REFETCH passes over what is already there. The providers are stand-ins
here; nothing touches the network or the library.

    python3 tests/test_subfind.py
"""
import json, os, pathlib, sys, tempfile

os.environ["HOME"] = tempfile.mkdtemp(prefix="subfind-")
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "scripts"))
import codec_serve as cs
_REAL_SUBSOURCE = cs._subsource_fetch   # later sections stand in for the provider

fails = 0


def check(name, got, want):
    global fails
    ok = got == want
    fails += 0 if ok else 1
    print(f"  {'ok ' if ok else 'FAIL'} {name}: {got!r}" + ("" if ok else f" (want {want!r})"))


def srt(n_cues, last_s, garble=False, sdh=False):
    """An SRT with n cues ending at last_s seconds."""
    out = []
    for i in range(n_cues):
        t0 = last_s * i / max(1, n_cues - 1) if n_cues > 1 else last_s
        t1 = t0 + 1.0
        def ts(x):
            h, r = divmod(x, 3600); m, s = divmod(r, 60)
            return f"{int(h):02d}:{int(m):02d}:{int(s):02d},{int((s - int(s)) * 1000):03d}"
        line = "I'm sorry, Dave" if i % 2 else "I'm afraid I can't do that"
        if garble:
            line = "ENGlNES REVV|NG" if i % 3 else "lTS A TRAP"
        if sdh and i % 2:
            line = "[DOOR OPENS]"
        out += [str(i + 1), f"{ts(t0)} --> {ts(t1)}", line, ""]
    return "\n".join(out).encode("utf-8")


print("sub_query")
check("year anchors the title", cs.sub_query("The.Proper.Way.2019.1080p.WEB-DL.x264.mkv")[0],
      "The Proper Way")
check("whole-word junk", cs.sub_query("Charlottes.Webb.1080p.mkv")[0], "Charlottes Webb")
check("junk cut without a year", cs.sub_query("Some.Film.1080p.BluRay.x265.mkv")[0], "Some Film")
check("episode anchors", cs.sub_query("Show.S02E05.Title.720p.HDTV.mkv")[:4],
      ("Show", 0, 2, 5))
check("parenthesised year", cs.sub_query(
    "It's the Great Pumpkin, Charlie Brown (1966) (2160p BluRay x265 10bit HDR Tigole).mkv")[:2],
    ("It's the Great Pumpkin, Charlie Brown", 1966))

print("episode identity")
forms = cs._episode_forms(2, 5)
check("S02E05 is ours", cs._names_our_episode("Show.S02E05.WEB", forms, 2), True)
check("2x05 is ours", cs._names_our_episode("show 2x05 hdtv", forms, 2), True)
check("Season 1 Episode 5 is NOT our S02E05",
      cs._names_our_episode("Show Season 1 Episode 5", forms, 2), False)
check("Season 2 Episode 5 is ours", cs._names_our_episode("Show Season 2 Episode 5", forms, 2), True)
check("other episode named", cs._names_other_episode("Show.S02E04.WEB", 2, 5), True)
check("terse name left alone", cs._names_other_episode("Show.WEB.x264", 2, 5), False)

print("timing")
check("fits", cs._timing_fits(srt(200, 6000), 6420), True)
check("extended cut refused", cs._timing_fits(srt(200, 7000), 6420), False)
check("half a film refused", cs._timing_fits(srt(200, 2000), 6420), False)
check("unknown duration passes", cs._timing_fits(srt(200, 2000), 0), True)

print("the judge")
clean, rough = srt(200, 6000), srt(200, 6000, garble=True)
j = cs._SubJudge(6420)
check("rough is held, not taken", j.offer(rough, "Film.1080p.GROUP"), False)
check("…but remembered", j.best[0], rough)
check("clean is taken at once", j.offer(clean, "Film.2160p.OTHER"), True)
check("clean replaced rough as best", j.best[0], clean)
j2 = cs._SubJudge(6420, skip={__import__("hashlib").sha1(clean).hexdigest()})
check("a skipped file is refused", j2.offer(clean, "x"), False)
check("…and not remembered", j2.best, None)
check("wrong cut refused by the judge", cs._SubJudge(6420).offer(srt(200, 7000), "x"), False)
q_clean, _ = cs._sub_quality_text(clean.decode(), "Film.srt")
q_rough, _ = cs._sub_quality_text(rough.decode(), "Film.srt")
check("garble scores worse", q_rough > q_clean, True)
check("a forced file is penalised", cs._sub_quality_text(clean.decode(), "Film.forced.srt")[0] >= 100, True)
check("cp1252 decodes", cs._sub_text("caf\xe9".encode("cp1252")), "café")
check("BOM stripped", cs._sub_text(b"\xef\xbb\xbfhi"), "hi")

print("find_subtitle_ex (stand-in providers)")
lib = pathlib.Path(tempfile.mkdtemp(prefix="subfind-lib-"))
film = lib / "Film.2019.1080p.mkv"
film.write_bytes(b"\0" * 32)
cs.video_info = lambda src: {"dur": 6420.0}
offers = []
def fake_subsource(src, title, year, season, episode, want_dur=None, skip=()):
    judge = cs._SubJudge(want_dur or 0, skip)
    for raw, name, ext in offers:
        if judge.offer(raw, name, ext):
            return raw, name, ext
    return judge.best or (None, None, None)
cs._subsource_fetch = fake_subsource
cs._sub_cfg_key = lambda: ""
offers[:] = [(srt(200, 7000), "Film.EXTENDED.GROUP", ".srt"), (clean, "Film.1080p.GROUP", ".srt")]
r = cs.find_subtitle_ex(str(film))
check("the fitting one is saved", r.get("existing"), False)
check("named .en.srt", pathlib.Path(r["sub"]).name, "Film.2019.1080p.en.srt")
check("utf-8 on disk", pathlib.Path(r["sub"]).read_bytes()[:40], clean[:40])
check("no tmp left", sorted(p.name for p in lib.iterdir()), ["Film.2019.1080p.en.srt", "Film.2019.1080p.mkv"])
r2 = cs.find_subtitle_ex(str(film))
check("second call returns the existing", r2.get("existing"), True)
offers[:] = [(clean, "Film.1080p.GROUP", ".srt"), (srt(200, 6100), "Film.2160p.OTHER", ".ass")]
r3 = cs.find_subtitle_ex(str(film), force=True)
check("REFETCH passes over the file that is there", r3.get("existing"), False)
check("…and keeps the new one's extension", pathlib.Path(r3["sub"]).name, "Film.2019.1080p.en.ass")
check("…the old sidecar is gone", sorted(p.name for p in lib.iterdir()),
      ["Film.2019.1080p.en.ass", "Film.2019.1080p.mkv"])
def boom(*a, **k):
    raise OSError("connection refused")
cs._subsource_fetch = boom
r4 = cs.find_subtitle_ex(str(film), force=True)
check("an outage is retryable, not a miss", (r4.get("sub"), r4.get("retry")), (None, True))
cs._subsource_fetch = lambda *a, **k: (None, None, None)
r5 = cs.find_subtitle_ex(str(film), force=True)
check("a miss is a miss", (r5.get("sub"), bool(r5.get("retry"))), (None, False))

print("sub_style")
st = cs.sub_style(0.72, "mgshud|FFD400|1")
check("token font", "FontName=MGS1 HUD" in st, True)
check("token colour is BGR", "PrimaryColour=&H0000D4FF" in st, True)
check("boxed", "BorderStyle=3" in st, True)
check("size", "FontSize=12" in st, True)
st2 = cs.sub_style(1.0, "bogus|zzz|")
check("a bad token falls back to the config face", "FontName=MGS1 Codec" in st2, True)
check("outlined by default", "BorderStyle=1" in st2 and "FontSize" not in st2, True)

print("which title the search found (2026-10-13: Escape from L.A. for L.A. Confidential)")
check("punctuation never counts", cs._title_fit("L A Confidential", "L.A. Confidential"), 1.0)
check("a leading article never counts", cs._title_fit("X Files", "The X-Files"), 1.0)
check("another film that shares a word is no match", cs._title_fit("L A Confidential", "Escape from L.A.") < 0.6, True)
check("a renamed subtitle still matches", cs._title_fit("Ong Bak Muay Thai Warrior", "Ong-Bak: The Thai Warrior") >= 0.6, True)
check("a longer title on the same word is no match", cs._title_fit("Chronicle", "Chronicle of a Blood Merchant") < 0.6, True)
_search = {"results": [
    {"type": "tvseries", "releaseYear": 2004, "title": "The L Word", "link": "/series/the-l-word"},
    {"type": "movie", "releaseYear": 1996, "title": "Escape from L.A.", "link": "/subtitles/escape-from-la-1996"},
    {"type": "movie", "releaseYear": 1997, "title": "L.A. Confidential", "link": "/subtitles/la-confidential-1997"}]}
_asked = []
def fake_http(url, headers=None, data=None, **k):
    _asked.append(url)
    return _search if url.endswith("/movie/search") else {"subtitles": []}
_real_http = cs._http_json
cs._http_json = fake_http
_REAL_SUBSOURCE("/x/L.A..Confidential.1997.1080p.mp4", "L A Confidential", 1997, 0, 0, want_dur=8000)
check("the search lists the film's OWN subtitles", any("la-confidential-1997" in u for u in _asked), True)
_asked.clear()
_REAL_SUBSOURCE("/x/The.L.Word.Generation.Q.S01E01.mkv", "Generation Q", 0, 1, 1, want_dur=3000)
check("a show nobody listed fetches nothing", [u for u in _asked if "/subtitles/" in u], [])
cs._http_json = _real_http

print("a season pack's own subtitles (Subs/<episode>/)")
pk = pathlib.Path(tempfile.mkdtemp(prefix="pack-"))
ep = pk / "Show.S01E07.1080p.mkv"; ep.write_bytes(b"\0")
(pk / "Subs" / "Show.S01E07.1080p").mkdir(parents=True)
(pk / "Subs" / "Show.S01E07.1080p" / "2_English.srt").write_bytes(srt(40, 2400))
(pk / "Subs" / "Show.S01E08.1080p").mkdir(parents=True)
(pk / "Subs" / "Show.S01E08.1080p" / "2_English.srt").write_bytes(srt(40, 2400))
cands = [os.path.relpath(c, pk) for c in cs._external_sub_candidates(str(ep))]
check("the episode's own folder is offered", cands, ["Subs/Show.S01E07.1080p/2_English.srt"])

print(f"\n{'ALL OK' if not fails else str(fails) + ' FAILED'}")
sys.exit(1 if fails else 0)
