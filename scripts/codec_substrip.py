#!/usr/bin/env python3
"""codec_substrip — drop subtitle tracks in languages nobody here reads.

A UHD BluRay remux ships every language the disc had. Measured across this
library on 2026-09-09: 790 files carrying 98.2 GB of subtitles, of which
85.1 GB is non-English. Goldfinger alone has 103 subtitle tracks; Star Wars
carries 2.8 GB of them. They are hdmv_pgs_subtitle — BITMAPS, one image per
line — which is why a text-shaped thing costs gigabytes.

Removing them is a container-level remux: mkvmerge copies the video and audio
packets untouched and simply writes fewer tracks. There is no re-encode, so
unlike almost everything else that frees space this costs no quality at all.
The DV RPU lives inside the video elementary stream and travels with it.

SAFETY
  * Never edits in place. Writes a sibling temp file, verifies it, and only then
    atomically replaces the original — so an interrupted run leaves the original
    whole and a stray .substrip file behind.
  * Verification is not "did mkvmerge exit 0": duration must match, the audio
    track count must be unchanged, every English subtitle must still be there,
    and sampled windows of the VIDEO STREAM must hash identically before and
    after. --paranoid hashes the whole video stream instead of samples.
  * Checks free space on the file's own drive FIRST. A 50 GB remux needs 50 GB
    free while both copies exist, and this library has drives sitting at 57 GB
    free — the same wall the DV normalizer hit on 2026-09-09.
  * Dry-run by default. Nothing is written without --apply.

  codec_substrip.py                     # report what it would reclaim
  codec_substrip.py --apply             # do it (>=100 MB of waste per file)
  codec_substrip.py --apply --min-mb 500 --limit 10
"""
import argparse
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

import sys as _sys, os as _os
import codec_paths  # where codec's data lives (~/.local/share/codec)
_sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
try:
    from codec_ui import yield_io as _yield_io
except ImportError:                       # ui module absent: not worth failing over
    def _yield_io():
        pass

CFG = Path.home() / ".config/codec/config.json"
_FF8 = Path.home() / "deps/ffmpeg-n8.1-static/bin"
FFPROBE = str(_FF8 / "ffprobe") if (_FF8 / "ffprobe").exists() else "ffprobe"
FFMPEG = str(_FF8 / "ffmpeg") if (_FF8 / "ffmpeg").exists() else "ffmpeg"
MKVMERGE = shutil.which("mkvmerge") or "mkvmerge"
LOG = Path.home() / ".cache/codec/substrip.log"

# Languages worth keeping. "und" is included on purpose: an untagged track is
# usually the English one, and keeping a track we did not need is free — dropping
# one we did is not.
KEEP_LANGS = {"eng", "en", "und", ""}

# TMDB answers in ISO 639-1, Matroska tags in 639-2 (and both bibliographic and
# terminological forms turn up in the wild). Only the languages this library
# actually contains need mapping; anything unmapped simply never matches, which
# fails SAFE — an unmatched original language keeps every track.
ISO1_TO_MKV = {
    "en": {"eng", "en"}, "ja": {"jpn", "ja"}, "id": {"ind", "id"},
    "th": {"tha", "th"}, "it": {"ita", "it"}, "ko": {"kor", "ko"},
    "fr": {"fre", "fra", "fr"}, "es": {"spa", "es"}, "de": {"ger", "deu", "de"},
    "ru": {"rus", "ru"}, "pt": {"por", "pt"}, "pl": {"pol", "pl"},
    "cs": {"cze", "ces", "cs"}, "zh": {"chi", "zho", "cmn", "yue", "zh"},
    "cn": {"chi", "zho", "cmn", "yue", "zh"},   # TMDB uses "cn" for Chinese
    "hi": {"hin", "hi"}, "sv": {"swe", "sv"}, "da": {"dan", "da"},
    "no": {"nor", "nob", "no"}, "fi": {"fin", "fi"}, "nl": {"dut", "nld", "nl"},
    "tr": {"tur", "tr"}, "ar": {"ara", "ar"}, "he": {"heb", "he"},
}
ORIGLANG_CACHE = Path.home() / ".cache/codec/origlang.json"
# Lossless audio is essentially never a dub — a disc carries the original in
# TrueHD/DTS-HD MA and the dubs in lossy AC3/EAC3. Treated as a keep signal in its
# own right, so a film whose original language we cannot establish still keeps it.
LOSSLESS_AUDIO = {"truehd", "flac", "mlp", "pcm_s16le", "pcm_s24le", "pcm_bluray",
                  "dts-hd master audio", "dts-hd ma"}
# Commentary and described audio are the "special features" tracks — always kept,
# whatever language they claim.
SPECIAL_RE = re.compile(r"comment|director|descri|narrat|isolated|score", re.I)


def log(msg):
    line = f"{time.strftime('%F %T')} {msg}"
    print(line, flush=True)
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        with open(LOG, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def run(cmd, timeout=None):
    """subprocess.run that DEGRADES on timeout instead of killing the pass.

    A bare TimeoutExpired propagates all the way out of the worklist scan, so a
    single pathological file aborts the whole run — and because the traceback
    goes to stderr while the exit status stays 0, it fails SILENTLY from the
    outside. That is how a 218-file pass stopped at 7 on 2026-09-12: one 2-CD
    rip whose ffprobe takes over 60s. Returning an empty result instead lets the
    caller treat it as "nothing to strip" and move on, which is the right answer
    for a file we cannot even read the track list of."""
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        print(f"    (probe timed out after {timeout}s, skipping: "
              f"{Path(cmd[-1]).name[:60]})", flush=True)
        return subprocess.CompletedProcess(cmd, 124, "", "timeout")


def sub_report(path):
    """(total_bytes, droppable_bytes, n_tracks, n_keep) for a file's subtitles."""
    out = run([FFPROBE, "-v", "error", "-select_streams", "s", "-show_entries",
               "stream_tags=language,NUMBER_OF_BYTES", "-print_format", "json",
               path], timeout=60).stdout
    ss = json.loads(out or "{}").get("streams") or []
    tot = drop = keep = 0
    for s in ss:
        tg = s.get("tags") or {}
        b = int(tg.get("NUMBER_OF_BYTES") or 0)
        tot += b
        if (tg.get("language") or "").lower() in KEEP_LANGS:
            keep += 1
        else:
            drop += b
    return tot, drop, len(ss), keep


def _orig_lang_map():
    """film path prefix -> original-language mkv tags, from the TMDB cache."""
    try:
        cache = json.loads(ORIGLANG_CACHE.read_text())
    except (OSError, ValueError):
        return {}
    try:
        con = sqlite3.connect(f"file:{codec_paths.DB}?mode=ro",
                              uri=True)
    except Exception:
        return {}
    roots = [r["path"] for r in json.loads(CFG.read_text())["roots"]]
    out = {}
    for path, tid in con.execute(
            "SELECT path,tmdb_id FROM metadata WHERE tmdb_id IS NOT NULL AND tmdb_id!=''"):
        ent = cache.get(str(tid))
        if not ent:
            continue
        tags = ISO1_TO_MKV.get(ent.get("orig") or "", set())
        if tags:
            # codec.db keys a movie on its VIDEO FILE, not its folder. Both sides
            # must reduce to the same thing or every lookup misses — which is how a
            # first run proposed dropping the Thai track from Ong Bak.
            out[_film_key(path, roots)] = tags
    return out


# Staging for files whose own drive cannot hold a second copy. The pool drives
# run at 94-96% full, so the biggest titles — exactly the ones carrying the most
# waste — were permanently unstrippable: Legends of the Fall is 71G of remux
# with 68 subtitle tracks on a drive with 34G free, and would never be reached.
# The NVMe system disk has room, so the remux is written THERE and placed back
# afterwards. This is the dv_normalize pattern, and it costs one extra copy.
SCRATCH = Path(os.environ.get(
    "CODEC_SUBSTRIP_SCRATCH",
    str(Path.home() / ".local/share/codec/substrip-scratch")))
SCRATCH_FLOOR = 80 * 1024**3        # never run the system disk down


def _scratch_room(need):
    """The scratch dir if it can hold `need` bytes above the floor, else None."""
    try:
        SCRATCH.mkdir(parents=True, exist_ok=True)
        free = shutil.disk_usage(SCRATCH).free
    except OSError:
        return None
    return SCRATCH if free - need > SCRATCH_FLOOR else None


def _drain_busy():
    """Is a DV drain (normalize / shrink / P7) running? It swaps a new file in
    at a title's exact path, and a strip that started on the OLD file would
    then overwrite (or, in scratch mode, delete) the freshly placed DV encode."""
    try:
        import codec_dv_normalize as dvn
        pid = int((Path(dvn.OUTDIR) / ".drain.lock").read_text().strip())
        return Path(f"/proc/{pid}").exists()
    except (ImportError, OSError, ValueError):
        return False


def _same_file(a, b):
    return (a.st_ino, a.st_size, int(a.st_mtime)) == (b.st_ino, b.st_size, int(b.st_mtime))


def _in_use(path):
    """Does any of our processes hold `path` open (a cast lane, mpv, a crop
    warm)? Unlinking it then frees nothing until they close it — the scratch
    place-back would run the drive to ENOSPC with the title already gone."""
    target = os.path.realpath(path)
    for fd_dir in Path("/proc").glob("[0-9]*/fd"):
        try:
            for fd in os.listdir(fd_dir):
                try:
                    if os.readlink(os.path.join(fd_dir, fd)) == target:
                        return True
                except OSError:
                    pass
        except OSError:
            pass
    return False


def _fsync(path):
    """Data on disk before a rename makes it the library's copy (ntfs3 + a power
    cut otherwise can leave a truncated file at the title's path)."""
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
    try:
        dfd = os.open(os.path.dirname(os.path.abspath(path)), os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    except OSError:
        pass


def finish_interrupted():
    """Complete a scratch place-back that was cut off (a stop, a shutdown, a
    power cut) — the window between deleting the original and landing the
    verified copy. The breadcrumb says where the film belongs; the .substrip on
    the scratch disk is COMPLETE and VERIFIED. Runs before each --apply pass."""
    try:
        crumbs = sorted(SCRATCH.glob("*.substrip.dest"))
    except OSError:
        return
    for crumb in crumbs:
        tmp = crumb.with_suffix("")                      # X.mkv.substrip
        try:
            d = json.loads(crumb.read_text())
            dest, size = Path(d["dest"]), int(d["size"])
        except (OSError, ValueError, KeyError):
            continue
        if not tmp.exists() or tmp.stat().st_size != size:
            log(f"RECOVER {dest.name}: breadcrumb but no complete scratch copy — left for a person")
            continue
        if dest.exists():
            if dest.stat().st_size == size:              # it landed; tidy up
                tmp.unlink(missing_ok=True)
                crumb.unlink(missing_ok=True)
            else:
                log(f"RECOVER {dest.name}: the original is still in place — scratch copy kept at {tmp}")
            continue
        local = dest.with_name(dest.name + ".substrip")
        try:
            shutil.copyfile(tmp, local)
            if local.stat().st_size != size:
                raise OSError(f"short copy ({local.stat().st_size} vs {size})")
            _fsync(local)
            os.replace(local, dest)
            tmp.unlink(missing_ok=True)
            crumb.unlink(missing_ok=True)
            log(f"RECOVER {dest.name}: interrupted place-back completed")
        except OSError as e:
            local.unlink(missing_ok=True)
            log(f"RECOVER {dest.name}: place-back failed again ({e}) — verified copy still at {tmp}")


def audio_plan(tracks, orig_tags):
    """(keep_ids, drop_ids) for the audio tracks of one file.

    A track is dropped ONLY if every one of these is false, because the cost of a
    wrong drop is the film's own soundtrack:
      * it is English or untagged
      * it is the ORIGINAL language (Akira is Japanese, The Raid Indonesian, the
        Leone westerns Italian — dropping "foreign" audio would have gutted them)
      * it is commentary / described / isolated score — the special-feature audio
      * it is LOSSLESS, which a dub essentially never is
      * it is the largest track in the file
    And the result can never be empty: if nothing survives, nothing is dropped."""
    # Without an authoritative original language there is nothing to protect the
    # native track WITH. Ong Bak's tracks carry no byte counts either, so "keep the
    # largest" silently evaluated to nothing and the Thai audio came up droppable.
    # A film we cannot identify keeps every track it has.
    if not orig_tags:
        return [(t["id"], "original language unknown") for t in tracks], []
    keep, drop = [], []
    sizes = [(t.get("size") or 0) for t in tracks]
    biggest = max(sizes) if sizes else 0
    if biggest <= 0:
        # No byte counts at all — the size-based protection cannot work, so do not
        # rely on the others alone.
        return [(t["id"], "no track sizes available") for t in tracks], []
    for t in tracks:
        lang = (t.get("lang") or "und").lower()
        title = t.get("title") or ""
        codec = (t.get("codec") or "").lower()
        why = None
        if lang in KEEP_LANGS:
            why = "english/untagged"
        elif orig_tags and lang in orig_tags:
            why = "ORIGINAL language"
        elif SPECIAL_RE.search(title):
            why = "commentary/described"
        elif any(k in codec for k in LOSSLESS_AUDIO):
            why = "lossless"
        elif (t.get("size") or 0) >= biggest and biggest > 0:
            why = "largest track"
        if why:
            keep.append((t["id"], why))
        else:
            drop.append((t["id"], lang, t.get("size") or 0))
    if not keep:                       # never leave a file mute
        return [(t["id"], "last resort") for t in tracks], []
    return keep, drop


def mkv_audio_tracks(path):
    """mkvmerge's audio tracks with the byte counts ffprobe reports."""
    out = run([MKVMERGE, "-J", path], timeout=120).stdout
    j = json.loads(out or "{}")
    sizes = {}
    try:
        pr = run([FFPROBE, "-v", "error", "-select_streams", "a", "-show_entries",
                  "stream=index:stream_tags=NUMBER_OF_BYTES", "-print_format", "json",
                  path], timeout=60).stdout
        for i, st in enumerate(json.loads(pr or "{}").get("streams") or []):
            sizes[i] = int((st.get("tags") or {}).get("NUMBER_OF_BYTES") or 0)
    except Exception:
        pass
    tracks, n = [], 0
    for t in j.get("tracks", []):
        if t.get("type") != "audio":
            continue
        pr_ = t.get("properties", {})
        tracks.append({"id": t["id"], "lang": (pr_.get("language") or "und").lower(),
                       "title": pr_.get("track_name") or "",
                       "codec": (t.get("codec") or "").lower(),
                       "size": sizes.get(n, 0)})
        n += 1
    return tracks


def mkv_sub_tracks(path):
    """mkvmerge's own track ids for subtitles — NOT ffprobe stream indices; they
    are different numbering schemes and mixing them silently keeps the wrong ones."""
    out = run([MKVMERGE, "-J", path], timeout=120).stdout
    j = json.loads(out or "{}")
    keep, drop = [], []
    for t in j.get("tracks", []):
        if t.get("type") != "subtitles":
            continue
        lang = (t.get("properties", {}).get("language") or "").lower()
        (keep if lang in KEEP_LANGS else drop).append(t["id"])
    return keep, drop


# How much the CONTAINER may shrink once longer-running non-video tracks are
# dropped. Generous because the offenders measured here ran 3-12s past the
# picture; growth is still rejected outright at 1.0s.
DUR_SHRINK_MAX = 60.0


def probe_basics(path):
    out = run([FFPROBE, "-v", "error", "-show_streams", "-show_format",
               "-print_format", "json", path], timeout=90).stdout
    j = json.loads(out or "{}")
    st = j.get("streams") or []
    return {
        "dur": float((j.get("format") or {}).get("duration") or 0),
        "naud": sum(1 for s in st if s.get("codec_type") == "audio"),
        "nsub": sum(1 for s in st if s.get("codec_type") == "subtitle"),
        "nvid": sum(1 for s in st if s.get("codec_type") == "video"),
    }


def video_md5(path, dur, paranoid=False):
    """Hash of COPIED video packets. Proves the picture is untouched — the one
    claim worth verifying, since it is the only thing that could not be undone."""
    if paranoid:
        r = run([FFMPEG, "-v", "error", "-i", path, "-map", "0:v:0", "-c", "copy",
                 "-f", "md5", "-"], timeout=3600)
        return [(r.stdout or "").strip()]
    hs = []
    for f in (0.05, 0.5, 0.9):
        r = run([FFMPEG, "-v", "error", "-ss", f"{dur*f:.2f}", "-t", "6", "-i", path,
                 "-map", "0:v:0", "-c", "copy", "-f", "md5", "-"], timeout=180)
        hs.append((r.stdout or "").strip())
    return hs


def strip_one(path, paranoid=False, orig_tags=None, do_audio=True):
    """Remux without the unwanted subtitle (and optionally audio) tracks.
    Returns (bytes_saved, message)."""
    src = Path(path)
    # The worklist is built ONCE and then worked for hours, during which other
    # jobs (duplicate cleanup, the DV normalizer's place-and-trash) legitimately
    # delete or move files out from under it. That is not a failure of this tool
    # and must not be counted as one — check now, while the answer still means
    # something. (Found 2026-09-09: The Last Samurai was removed as a duplicate
    # an hour into a 70-file pass and logged as "FAIL mkvmerge:" with no text.)
    if not src.exists():
        return 0, "GONE — removed by another job since the scan"
    keep_ids, drop_ids = mkv_sub_tracks(path)
    a_keep, a_drop = ([], [])
    if do_audio:
        a_keep, a_drop = audio_plan(mkv_audio_tracks(path), orig_tags or set())
    if not drop_ids and not a_drop:
        return 0, "nothing to drop"
    if _drain_busy():
        return 0, "SKIP a DV drain is running (it may swap this very file in place)"

    pre = src.stat()              # the file being remuxed — re-checked before the swap
    before_sz = pre.st_size
    free = shutil.disk_usage(src.parent).free
    scratch = None
    if free < before_sz * 1.05:
        # The drive cannot hold both copies. Stage on the NVMe instead and place
        # the result back afterwards — see SCRATCH. Only if THAT has room too.
        scratch = _scratch_room(int(before_sz * 1.05))
        if scratch is None:
            return 0, (f"SKIP no room — needs ~{before_sz/1024**3:.0f}G free while both "
                       f"copies exist, {free/1024**3:.0f}G on this drive and the "
                       f"scratch cannot take it either")

    b4 = probe_basics(path)
    if b4["dur"] <= 0:
        return 0, "SKIP unreadable duration"
    md5_before = video_md5(path, b4["dur"], paranoid)

    tmp = ((scratch / (src.name + ".substrip")) if scratch
           else src.with_name(src.name + ".substrip"))
    cmd = [MKVMERGE, "-q", "-o", str(tmp)]
    cmd += (["-s", ",".join(str(i) for i in keep_ids)] if keep_ids else ["-S"])
    if do_audio and a_drop:
        cmd += ["-a", ",".join(str(i) for i, _ in a_keep)]
    cmd += [str(src)]
    r = run(cmd, timeout=7200)
    if r.returncode not in (0, 1) or not tmp.exists():   # 1 == warnings only
        tmp.unlink(missing_ok=True)
        # mkvmerge is run with -q and can fail silently (and a timeout carries no
        # output at all), so the raw text is often empty — an empty reason in the
        # log is worse than none, because it looks like a bug in the reporting
        # rather than in the run. Always say something falsifiable.
        why = (r.stderr or r.stdout or "").strip()[:120]
        if not why:
            why = (f"exit {r.returncode}, no output"
                   + ("" if tmp.exists() else "; output file was never created")
                   + ("" if src.exists() else "; SOURCE DISAPPEARED mid-remux"))
        return 0, f"FAIL mkvmerge: {why}"

    # ── verify before anything irreversible happens ───────────────────────────
    try:
        af = probe_basics(str(tmp))
        problems = []
        # format.duration is the CONTAINER duration — the longest track, not the
        # video. Dropping a commentary or a subtitle that runs past the picture
        # legitimately SHRINKS it, which is precisely what this tool is for. The
        # old +/-1.0s window called that corruption and permanently rejected 8
        # films (Rear Window, Lethal Weapon, Django, Sahara, Die Hard, Bourne
        # Identity, Man of Steel, The Prestige), each re-remuxed from scratch on
        # every pass — ~80 min of 4K remuxing per night that could never succeed.
        #
        # A shrink is expected; GROWTH is not, and truncation is caught by the
        # md5 below, which samples at the ORIGINAL duration's 0.9 mark and so
        # fails if the picture no longer reaches that far.
        d_delta = af["dur"] - b4["dur"]
        if d_delta > 1.0:
            problems.append(f"duration GREW {af['dur']:.1f}s vs {b4['dur']:.1f}s")
        elif d_delta < -DUR_SHRINK_MAX:
            problems.append(f"duration {af['dur']:.1f}s vs {b4['dur']:.1f}s")
        want_aud = len(a_keep) if (do_audio and a_drop) else b4["naud"]
        if af["naud"] != want_aud:
            problems.append(f"audio tracks {af['naud']}, expected {want_aud}")
        if do_audio and a_drop and af["naud"] < 1:
            problems.append("no audio left")
        if af["nvid"] != b4["nvid"]:
            problems.append(f"video tracks {af['nvid']} vs {b4['nvid']}")
        if af["nsub"] != len(keep_ids):
            problems.append(f"kept {af['nsub']} subs, expected {len(keep_ids)}")
        if tmp.stat().st_size >= before_sz:
            problems.append("output is not smaller")
        # Hash the SAME ABSOLUTE OFFSETS on both sides. video_md5 samples at
        # fractions of the duration it is handed, so passing af["dur"] here
        # compared different parts of the film whenever the duration shifted at
        # all — byte-identical video then reported as changed. Using b4["dur"]
        # for both also turns the check into a truncation test for free.
        if not problems and video_md5(str(tmp), b4["dur"], paranoid) != md5_before:
            problems.append("VIDEO STREAM CHANGED")
        if problems:
            tmp.unlink(missing_ok=True)
            return 0, "FAIL verify: " + "; ".join(problems)
    except Exception as e:
        tmp.unlink(missing_ok=True)
        return 0, f"FAIL verify: {e}"

    saved = before_sz - tmp.stat().st_size
    old_stat = src.stat()         # capture BEFORE the swap — needed to re-key caches
    # The verify compared against the file as it was when the remux STARTED.
    # If something replaced it since (the DV drain placing a new encode at
    # this exact path), swapping now would destroy that work.
    if not _same_file(old_stat, pre):
        tmp.unlink(missing_ok=True)
        return 0, "SKIP the file was replaced during the remux (left untouched)"
    try:
        _fsync(tmp)
    except OSError as e:
        tmp.unlink(missing_ok=True)
        return 0, f"FAIL flush: {e}"
    if scratch is None:
        os.replace(tmp, src)      # same directory => atomic
    else:
        # The drive could not hold both copies, so the original must GO before
        # the replacement can land. That opens a window in which the only copy
        # of the film is the scratch file — which is why nothing here runs until
        # the verify above has passed, including the video MD5. A breadcrumb
        # records where the file belongs so an interrupted place-back is
        # recoverable by hand rather than a mystery: the .substrip on the NVMe
        # is a COMPLETE, VERIFIED film, not a partial.
        new_sz = tmp.stat().st_size
        crumb = tmp.with_suffix(tmp.suffix + ".dest")
        try:
            crumb.write_text(json.dumps({"dest": str(src), "size": new_sz}))
        except OSError:
            pass
        local = src.with_name(src.name + ".substrip")
        if _in_use(src):
            tmp.unlink(missing_ok=True)
            crumb.unlink(missing_ok=True)
            return 0, "SKIP the file is open (playing or casting) — next pass"
        try:
            os.unlink(src)                       # ← window opens
            shutil.copyfile(tmp, local)
            if local.stat().st_size != new_sz:
                local.unlink(missing_ok=True)
                return 0, (f"FAIL place-back short — the VERIFIED film is still at "
                           f"{tmp}; the next --apply run places it (finish_interrupted)")
            _fsync(local)
            os.replace(local, src)               # ← window closes, atomically
        except OSError as e:
            # Never leave a partial filling the drive the title just left.
            local.unlink(missing_ok=True)
            return 0, (f"FAIL place-back: {e} — the VERIFIED film is still at "
                       f"{tmp}; the next --apply run places it (finish_interrupted)")
        tmp.unlink(missing_ok=True)
        crumb.unlink(missing_ok=True)
    carried = _carry_video_caches(str(src), old_stat)
    skip_kept = _carry_dv_skip(str(src), old_stat)
    bits = [f"{len(drop_ids)} sub"]
    if a_drop:
        bits.append(f"{len(a_drop)} audio ({','.join(sorted({l for _, l, _ in a_drop}))})")
    return saved, (f"OK dropped {' + '.join(bits)}, kept {len(keep_ids)} sub/"
                   f"{len(a_keep) if do_audio else b4['naud']} audio, "
                   f"freed {saved/1024**2:.0f} MB"
                   + (", crop timeline carried over" if carried else "")
                   + (", DV skip preserved" if skip_kept else ""))


def _carry_dv_skip(src, old_stat):
    """Carry a DV normalize SKIP decision across the remux.

    The skip list is fingerprinted path|size|mtime so that a re-downloaded file
    is retried rather than skipped forever. A track strip changes both, which
    silently revoked a decision the author made deliberately: Jaws was skip-listed as
    "AI-RIFE 60fps, ~2h of GPU for a near-certain skip", stripped at 19:39, and
    the drain started encoding it at 03:42.

    Carrying it is sound for the same reason the crop timeline is: the replace
    only happens once the VIDEO STREAM's MD5 is proven identical, and both the
    DV verdict and the skip reason depend on the video layer alone. A different
    container is not a different film."""
    try:
        # The drain's OWN list (it moved with OUTDIR to _dvnorm-scratch; a
        # hardcoded _dvnorm/ path updated a stale copy the drain never reads).
        import codec_dv_normalize as dvn
        skiplist = Path(dvn.SKIPLIST)
        d = json.loads(skiplist.read_text())
        key = os.path.abspath(src)
        e = d.get(key)
        if not e or e.get("sig") != [old_stat.st_size, int(old_stat.st_mtime)]:
            return False
        ns = os.stat(src)
        e["sig"] = [ns.st_size, int(ns.st_mtime)]
        tmp = str(skiplist) + ".tmp"
        with open(tmp, "w") as f:
            json.dump(d, f, indent=1)
        os.replace(tmp, skiplist)
        return True
    except (OSError, ValueError, KeyError, ImportError):
        return False


def _carry_video_caches(src, old_stat):
    """Re-key any cache derived purely from the VIDEO stream onto the new file.

    Codec's caches are keyed on path|size|mtime, deliberately — a path alone lets
    a swapped file inherit a dead file's verdict. Stripping tracks changes size
    and mtime, so every such cache entry is orphaned by a remux and the film
    silently reverts to "never measured".

    That cost real work: Interstellar's crop timeline (17 segments, ~18 minutes
    of decoding) was discarded the moment its Italian and Spanish tracks were
    dropped, and nothing would ever have rebuilt it — reconcile strips two files
    on EVERY import, so any warmed film could lose its timeline at any time.

    Carrying it over is sound precisely BECAUSE of the check above: the replace
    only happens once the video stream's MD5 is proven identical. The pixels are
    the same bytes; only the container changed. Anything derived from audio or
    subtitle tracks would NOT be safe to carry, and none is carried here."""
    try:
        import hashlib
        old_key = f"{os.path.abspath(src)}|{old_stat.st_size}|{int(old_stat.st_mtime)}"
        ns = os.stat(src)
        new_key = f"{os.path.abspath(src)}|{ns.st_size}|{int(ns.st_mtime)}"
        d = Path.home() / ".cache/codec/croptl"
        o = d / (hashlib.sha1(old_key.encode()).hexdigest() + ".json")
        n = d / (hashlib.sha1(new_key.encode()).hexdigest() + ".json")
        if o.exists() and not n.exists():
            os.replace(o, n)
            return True
    except OSError:
        pass
    return False


def _film_key(path, roots):
    """The codec.db path this file belongs to — rows are keyed on the TITLE, which
    is the folder directly under a library root (or the file itself when loose)."""
    for r in roots:
        if path.startswith(r + "/"):
            rest = path[len(r) + 1:].split("/")
            return os.path.join(r, rest[0])
    return path


def candidates(min_mb, only=None, do_audio=True):
    roots = [r["path"] for r in json.loads(CFG.read_text())["roots"]]
    origmap = _orig_lang_map() if do_audio else {}
    if only:
        # Lets a bulk pass avoid a drive that is busy — the DV normalizer's scratch
        # lives on Movies7, and a 50 GB remux reading/writing the same spindle as an
        # nvenc encode just makes both slow.
        # Path-component match, NOT a plain prefix: "/mnt/Movies" is a prefix of
        # "/mnt/Movies3", so startswith() silently selects every drive.
        only = [o.rstrip("/") for o in only]
        roots = [r for r in roots
                 if any(r == o or r.startswith(o + "/") for o in only)]
    seen, out = set(), []
    for root in roots:
        for dp, _, fs in os.walk(root):
            if "_dvnorm-trash" in dp or "_dupes-trash" in dp or "_dvnorm" in dp \
                    or ".importing" in dp:      # a torrent import mid-copy
                continue
            for f in fs:
                if not f.lower().endswith(".mkv"):
                    continue
                p = os.path.join(dp, f)
                if p in seen:
                    continue
                seen.add(p)
                tot, drop, n, nk = sub_report(p)
                adrop = 0
                a_drop = []
                if do_audio:
                    a_keep, a_drop = audio_plan(mkv_audio_tracks(p),
                                                origmap.get(_film_key(p, roots)) or set())
                    adrop = sum(sz for _, _, sz in a_drop)
                if drop + adrop >= min_mb * 1024**2:
                    out.append((drop + adrop, n, nk, p, drop, adrop, len(a_drop)))
    out.sort(reverse=True)
    return out


LOCK = Path.home() / ".cache/codec/substrip.lock"


def acquire_lock():
    """Refuse to start a second --apply run.

    codec_reconcile.sh calls this tool whenever codec rescans the library, so a
    manual bulk pass and an import-triggered one can collide — and they did, on
    2026-09-09, while a 34 GB remux was in flight. Two runs sort the same
    candidates the same way, so they pick the SAME file: one replaces the original
    while the other is still reading it, and whichever finishes second silently
    discards the other's work. Same reasoning (and shape) as the DV drain's lock.

    A lock left by a killed process is reclaimed rather than blocking forever."""
    try:
        LOCK.parent.mkdir(parents=True, exist_ok=True)
        if LOCK.exists():
            try:
                pid = int(LOCK.read_text().strip())
            except (ValueError, OSError):
                pid = 0
            if pid and Path(f"/proc/{pid}").exists():
                return pid              # a real run owns it
        LOCK.write_text(str(os.getpid()))
        return 0
    except OSError:
        return 0                        # never let a lock problem stop real work


def release_lock():
    try:
        if LOCK.exists() and LOCK.read_text().strip() == str(os.getpid()):
            LOCK.unlink()
    except OSError:
        pass


def _running():
    """PID of a live --apply run, or 0. Reads /proc rather than pgrep, which would
    also match the shell that invoked it (a trap this repo has hit before)."""
    me = os.getpid()
    for d in os.listdir("/proc"):
        if not d.isdigit() or int(d) == me:
            continue
        try:
            cmd = open(f"/proc/{d}/cmdline", "rb").read().decode("utf-8", "replace")
        except OSError:
            continue
        if "codec_substrip.py" in cmd and "--apply" in cmd:
            return int(d)
    return 0


def _live_remux():
    """(bytes written, bytes expected, name) for the remux happening RIGHT NOW.

    mkvmerge is given "-o <tmp> … <src>", so the in-flight file and its expected
    final size can be read straight off the running child — no state file to
    keep in sync, and it works for a pass that was already running before this
    code existed.

    Matched on argv[0], never on the whole command line: a shell whose command
    text merely CONTAINS "mkvmerge" matches otherwise, which is the same trap
    that had pgrep -f reporting finished jobs as running."""
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            with open(f"/proc/{d}/cmdline", "rb") as f:
                argv = f.read().decode("utf-8", "replace").split("\0")
        except OSError:
            continue
        argv = [x for x in argv if x]
        if not argv or os.path.basename(argv[0]) != "mkvmerge":
            continue
        try:
            out = argv[argv.index("-o") + 1]
            src = argv[-1]
            # The output can only ever be smaller than the source — that is the
            # entire point — so the source size is the ceiling, not the target.
            return os.path.getsize(out), os.path.getsize(src), os.path.basename(src)
        except (ValueError, IndexError, OSError):
            return None
    return None


def status_data():
    """Machine-readable progress: the ONE parser of this tool's log.

    status_line() and the dashboard both used to read the log themselves, in
    slightly different ways — so the header could disagree with the panel it
    was heading. Parse once here; render twice, above."""
    lines = LOG.read_text(errors="replace").splitlines() if LOG.exists() else []
    done = sum(1 for l in lines if "OK dropped" in l)
    freed = sum(int(m.group(1)) for m in
                (re.search(r"freed (\d+) MB", l) for l in lines) if m)
    pid = _running()
    at = total = 0
    cur = ""
    for l in reversed(lines):
        m = re.search(r"\[(\d+)/(\d+)\] (.+)$", l)
        if m:
            at, total, cur = int(m.group(1)), int(m.group(2)), m.group(3).strip()
            break
    # Bytes the remux has moved, read AND written. The position counter only
    # advances when a whole FILE lands, and a 40 GB remux holds it still for
    # many minutes — plus the pass opens with a scan during which nothing moves
    # at all. Without this the watcher judges a working strip pass on a frozen
    # number, which is how it reported "on the same file for 2091m" sixteen
    # minutes into a healthy run. /proc io moves the instant mkvmerge does.
    # ⚠ `ps %cpu` is NOT a substitute — it is a lifetime average.
    io_bytes = 0
    try:
        for d in os.listdir("/proc"):
            if not d.isdigit():
                continue
            try:
                with open(f"/proc/{d}/cmdline", "rb") as f:
                    argv = f.read().decode("utf-8", "replace")
                if os.path.basename(argv.split("\0")[0]) not in (
                        "mkvmerge", "mkvextract", "ffmpeg", "ffprobe"):
                    continue
                if "/mnt/" not in argv:
                    continue
                with open(f"/proc/{d}/io") as f:
                    for line in f:
                        k, _, v = line.partition(":")
                        if k in ("read_bytes", "write_bytes"):
                            io_bytes += int(v)
            except (OSError, ValueError, IndexError):
                continue
    except OSError:
        pass

    return {"name": "Subtitle / audio strip", "icon": "✂", "short": "Strip",
            "io_bytes": io_bytes,
            "pid": pid, "running": bool(pid),
            "at": at, "total": total, "done": done, "current": cur,
            # Overall progress, which only the tool can define: for a strip
            # pass it is position in the worklist it was given.
            "prog_at": at, "prog_of": total,
            "live": _live_remux(),
            "started": (os.stat(f"/proc/{pid}").st_mtime if pid else None),
            "detail": f"{freed/1024:.1f} GB freed", "freed_gb": freed / 1024}


def status_line():
    """One compact line for the rofi header — log + process state only, no disk
    scan, so opening the menu is instant."""
    d = status_data()
    if d["running"] and d["total"]:
        return (f"✂ [{d['at']}/{d['total']}] {d['current'][:38]} · "
                f"{d['done']} done · {d['detail']}")
    if d["done"]:
        return f"✂ idle · {d['done']} file(s) stripped · {d['detail']}"
    return "✂ idle"


_LOGTS = re.compile(r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\s*")


def status():
    """The full picture, for a terminal."""
    lines = LOG.read_text(errors="replace").splitlines() if LOG.exists() else []
    pid = _running()
    print("═══ Subtitle / audio strip — status ═══")
    print(f"  process   : {'RUNNING (pid %d)' % pid if pid else 'idle'}")
    ok = [l for l in lines if "OK dropped" in l]
    freed = sum(int(m.group(1)) for l in lines
                for m in [re.search(r"freed (\d+) MB", l)] if m)
    print(f"  completed : {len(ok)} file(s), {freed/1024:.1f} GB freed")
    for l in ok[-8:]:
        print(f"      {_LOGTS.sub('', l).strip()[:96]}")
    skipped = [l for l in lines if "SKIP" in l]
    failed = [l for l in lines if "FAIL" in l]
    if skipped:
        print(f"  skipped   : {len(skipped)}")
        for l in skipped[-3:]:
            print(f"      {_LOGTS.sub('', l).strip()[:96]}")
    if failed:
        print(f"  failed    : {len(failed)}")
        for l in failed[-3:]:
            print(f"      {_LOGTS.sub('', l).strip()[:96]}")
    if pid:
        for l in reversed(lines):
            m = re.search(r"\[(\d+/\d+)\] (.+)$", l)
            if m:
                print(f"  in progress: [{m.group(1)}] {m.group(2).strip()[:70]}")
                break


def main():
    ap = argparse.ArgumentParser(description="drop unwanted-language subtitle tracks")
    ap.add_argument("--apply", action="store_true", help="actually remux (default: report)")
    ap.add_argument("--min-mb", type=int, default=100,
                    help="only touch files wasting at least this much (default 100)")
    ap.add_argument("--limit", type=int, default=0, help="stop after N files")
    ap.add_argument("--root", action="append", default=None, metavar="PATH",
                    help="restrict to library roots under PATH (repeatable)")
    ap.add_argument("--one", metavar="PATH",
                    help="operate on a single file (implies --apply)")
    ap.add_argument("--no-audio", dest="no_audio", action="store_true",
                    help="subtitles only; leave every audio track alone")
    ap.add_argument("--status", action="store_true", help="what the last/current run did")
    ap.add_argument("--status-json", dest="status_json", action="store_true",
                    help="machine-readable progress for the dashboard")
    ap.add_argument("--status-line", dest="status_line", action="store_true",
                    help="one line, for the rofi header")
    ap.add_argument("--paranoid", action="store_true",
                    help="hash the WHOLE video stream instead of sampling it")
    a = ap.parse_args()
    _yield_io()   # background work never blocks NFS or playback

    # Status must answer instantly and without mkvmerge — the rofi header calls it
    # every time the menu opens.
    if a.status_json:
        print(json.dumps(status_data()))
        return
    if a.status_line:
        print(status_line())
        return
    if a.status:
        status()
        return

    if not shutil.which(MKVMERGE) and not os.path.exists(MKVMERGE):
        sys.exit("mkvmerge not found — " + codec_paths.install_hint("mkvmerge"))

    if a.one:
        roots = [r["path"] for r in json.loads(CFG.read_text())["roots"]]
        origmap = _orig_lang_map() if not a.no_audio else {}
        tags = origmap.get(_film_key(a.one, roots)) or set()
        tot, drop, n, nk = sub_report(a.one)
        print(f"{Path(a.one).name}")
        print(f"  {n} subtitle track(s), {nk} kept, "
              f"{drop/1024**2:.0f} MB droppable of {tot/1024**2:.0f} MB")
        if not a.no_audio:
            ak, ad = audio_plan(mkv_audio_tracks(a.one), tags)
            print(f"  audio: keep {len(ak)} ({', '.join(w for _, w in ak)}), "
                  f"drop {len(ad)} ({', '.join(l for _, l, _ in ad) or '-'})")
        held = acquire_lock()
        if held:
            print(f"  another strip pass is running (pid {held}) — refusing")
            return
        try:
            finish_interrupted()
            saved, msg = strip_one(a.one, a.paranoid, tags, not a.no_audio)
            log(f"  {msg}")
        finally:
            release_lock()
        return

    print(f"scanning for files wasting >= {a.min_mb} MB on unwanted subtitles …",
          flush=True)
    do_audio = not a.no_audio
    cands = candidates(a.min_mb, a.root, do_audio)
    total = sum(c[0] for c in cands)
    tsub = sum(c[4] for c in cands)
    taud = sum(c[5] for c in cands)
    print(f"\n{len(cands)} file(s), {total/1024**3:.1f} GB reclaimable"
          f"  ({tsub/1024**3:.1f} GB subtitles + {taud/1024**3:.1f} GB audio)\n")
    for drop, n, nk, p, sd, ad, nad in cands[:40]:
        extra = f" +{nad} audio" if nad else ""
        print(f"  {drop/1024**2:6.0f} MB  {n:>3} subs ({nk} kept){extra:>10}  {Path(p).name[:52]}")
    if len(cands) > 40:
        print(f"  … and {len(cands)-40} more")

    if not a.apply:
        print("\nreport only — nothing written. Re-run with --apply to reclaim it.")
        return

    if a.limit:
        cands = cands[:a.limit]
    held = acquire_lock()
    if held:
        print(f"\nanother strip pass is already running (pid {held}) — refusing to start. "
              f"Two runs pick the same files and clobber each other's work.")
        return
    finish_interrupted()
    print(f"\n═══ remuxing {len(cands)} file(s) ═══")
    freed = ok = skipped = failed = gone = 0
    roots = [r["path"] for r in json.loads(CFG.read_text())["roots"]]
    origmap = _orig_lang_map() if do_audio else {}
    for i, (drop, n, nk, p, sd, ad, nad) in enumerate(cands, 1):
        log(f"[{i}/{len(cands)}] {Path(p).name[:70]}")
        saved, msg = strip_one(p, a.paranoid,
                               origmap.get(_film_key(p, roots)) or set(), do_audio)
        log(f"    {msg}")
        freed += saved
        ok += msg.startswith("OK")
        skipped += msg.startswith("SKIP") or msg == "nothing to drop"
        gone += msg.startswith("GONE")
        failed += msg.startswith("FAIL")
    log(f"═══ done: {ok} remuxed, {skipped} skipped, "
        + (f"{gone} vanished, " if gone else "")
        + f"{failed} failed, {freed/1024**3:.1f} GB freed ═══")
    release_lock()


if __name__ == "__main__":
    main()
