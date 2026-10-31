#!/usr/bin/env python3
"""codec_sfx_forge — synthesise codec's UI sound packs into assets/sfx/.

Every sound is made from scratch here (oscillators, noise, resonators — no
samples, nothing to license). Every pack carries the same five cues, so a pack
can be swapped without touching a view:

    move    the selection steps (wheel, spotlight, posters)
    bump    a step that can't go any further (the wheel's ends)
    select  enter: open a section, play a film
    back    esc, or a panel closing
    open    a panel or deck opening (the info sheet, CONTINUE)

Output: assets/sfx/<pack>/<cue>.wav — 48 kHz, 16-bit, mono (codec pans at mix
time). Each cue is levelled on a K-weighted short-term loudness so packs sit at
the same loudness and the editor's SOUND LEVEL means the same thing on all of
them.

    scripts/codec_sfx_forge.py            # every pack
    scripts/codec_sfx_forge.py codec tick # just these

Then rebuild (the WAVs are baked into qrc). On a dev build there's no need to:
codec reads assets/sfx/ straight from the source tree whenever a pack is picked,
so re-running this and stepping the editor's NAV SOUND dial plays the new take.
"""
import sys
import wave
from pathlib import Path

import numpy as np

SR = 48000
OUT = Path(__file__).resolve().parent.parent / "assets" / "sfx"
RNG = np.random.default_rng(1977)   # fixed: a re-run writes the same bytes


# ── building blocks ─────────────────────────────────────────────────────────
def n_(dur):
    return max(1, int(round(dur * SR)))


def t_(dur):
    return np.arange(n_(dur)) / SR


def phase_of(freq, dur):
    """Running phase (cycles) for a constant or per-sample frequency."""
    f = np.full(n_(dur), float(freq)) if np.isscalar(freq) else np.asarray(freq, float)
    return np.cumsum(f) / SR


def sweep(f0, f1, dur, curve="exp"):
    x = np.linspace(0, 1, n_(dur))
    return f0 * (f1 / f0) ** x if curve == "exp" else f0 + (f1 - f0) * x


def sine(freq, dur, ph0=0.0):
    return np.sin(2 * np.pi * phase_of(freq, dur) + ph0)


def _blep(p, dt):
    y = np.zeros_like(p)
    a = p < dt
    x = p[a] / dt[a]
    y[a] = x + x - x * x - 1
    b = p > 1 - dt
    x = (p[b] - 1) / dt[b]
    y[b] = x * x + x + x + 1
    return y


def square(freq, dur, duty=0.5):
    """Band-limited (polyBLEP) pulse — chip voice without the aliasing fizz."""
    f = np.full(n_(dur), float(freq)) if np.isscalar(freq) else np.asarray(freq, float)
    dt = f / SR
    p = np.cumsum(dt) % 1.0
    s = np.where(p < duty, 1.0, -1.0)
    return s + _blep(p, dt) - _blep((p + (1 - duty)) % 1.0, dt)


def noise(dur):
    return RNG.uniform(-1, 1, n_(dur))


def env_exp(dur, tau, attack=0.0008):
    """Instant-ish attack, exponential decay. A sub-ms ramp keeps it click-free."""
    t = t_(dur)
    e = np.exp(-t / tau)
    if attack > 0:
        e *= np.clip(t / attack, 0, 1)
    return e


def env_bell(dur, peak_at, tau):
    """Swell to a peak, then decay — hiss, servo."""
    t = t_(dur)
    up = np.clip(t / max(peak_at, 1e-4), 0, 1) ** 2
    down = np.where(t > peak_at, np.exp(-(t - peak_at) / tau), 1.0)
    return up * down


def fade_tail(x, ms=4.0):
    k = min(len(x), n_(ms / 1000))
    x = x.copy()
    x[-k:] *= np.linspace(1, 0, k) ** 2
    return x


def fade_head(x, ms=3.0):
    """A clip cut out of a longer one starts mid-waveform — ramp it in, no click."""
    k = min(len(x), n_(ms / 1000))
    x = x.copy()
    x[:k] *= np.linspace(0, 1, k) ** 2
    return x


def at(dur, *parts):
    """Lay (offset_seconds, signal) parts on a fresh buffer `dur` long."""
    out = np.zeros(n_(dur))
    for off, sig in parts:
        i = n_(off) if off > 0 else 0
        j = min(len(out), i + len(sig))
        out[i:j] += sig[: j - i]
    return out


def biquad(x, kind, f, q=0.707, gain_db=0.0):
    """RBJ cookbook biquad (lp / hp / bp / hs)."""
    w = 2 * np.pi * f / SR
    cw, sw = np.cos(w), np.sin(w)
    al = sw / (2 * q)
    A = 10 ** (gain_db / 40)
    if kind == "lp":
        b = [(1 - cw) / 2, 1 - cw, (1 - cw) / 2]; a = [1 + al, -2 * cw, 1 - al]
    elif kind == "hp":
        b = [(1 + cw) / 2, -(1 + cw), (1 + cw) / 2]; a = [1 + al, -2 * cw, 1 - al]
    elif kind == "bp":
        b = [al, 0, -al]; a = [1 + al, -2 * cw, 1 - al]
    elif kind == "hs":
        sq = 2 * np.sqrt(A) * al
        b = [A * ((A + 1) + (A - 1) * cw + sq), -2 * A * ((A - 1) + (A + 1) * cw), A * ((A + 1) + (A - 1) * cw - sq)]
        a = [(A + 1) - (A - 1) * cw + sq, 2 * ((A - 1) - (A + 1) * cw), (A + 1) - (A - 1) * cw - sq]
    else:
        raise ValueError(kind)
    b0, b1, b2 = (v / a[0] for v in b)
    a1, a2 = a[1] / a[0], a[2] / a[0]
    y = np.zeros_like(x)
    x1 = x2 = y1 = y2 = 0.0
    for i, xi in enumerate(x):
        yi = b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1, y2, y1 = x1, xi, y1, yi
        y[i] = yi
    return y


def modes(dur, partials, ph=None):
    """Struck-object resonances: (freq, amp, decay tau) damped sines from t=0."""
    t = t_(dur)
    out = np.zeros_like(t)
    for k, (f, a, tau) in enumerate(partials):
        p0 = RNG.uniform(0, 2 * np.pi) if ph is None else ph
        out += a * np.sin(2 * np.pi * f * t + p0) * np.exp(-t / tau)
    return out


def fm(fc, ratio, index, dur, tau_amp, tau_idx):
    """Two-operator FM — the PS1-era bell/chime voice."""
    t = t_(dur)
    idx = index * np.exp(-t / tau_idx)
    mod = np.sin(2 * np.pi * fc * ratio * t)
    return np.sin(2 * np.pi * fc * t + idx * mod) * env_exp(dur, tau_amp)


def _comb(x, d, g):
    y = x.copy()
    for k in range(d, len(y), d):
        y[k:k + d] += g * y[k - d:k][: len(y[k:k + d])]
    return y


def _allpass(x, d, g):
    y = np.zeros_like(x)
    xd = np.concatenate([np.zeros(d), x])[: len(x)]
    for k in range(0, len(x), d):
        prev = y[k - d:k] if k >= d else np.zeros(min(d, len(x) - k))
        seg = slice(k, min(k + d, len(x)))
        n = seg.stop - seg.start
        y[seg] = -g * x[seg] + xd[seg] + g * prev[:n]
    return y


def room(x, wet=0.18, size=1.0, tail=0.25):
    """A small Schroeder room — a menu's air, not a cathedral."""
    x = np.concatenate([x, np.zeros(n_(tail))])
    combs = [0.0297, 0.0371, 0.0411, 0.0437]
    w = sum(_comb(x, n_(c * size), 0.62) for c in combs) / len(combs)
    w = _allpass(_allpass(w, n_(0.005), 0.6), n_(0.0017), 0.6)
    w = biquad(w, "lp", 6500)
    return x + wet * w


def crush(x, hold_hz=24000, bits=8):
    """Sample-and-hold + quantise: the 8-bit grit of a codec transmission."""
    step = max(1, int(round(SR / hold_hz)))
    y = np.repeat(x[::step], step)[: len(x)]
    q = 2 ** (bits - 1)
    return np.round(y * q) / q


# ── loudness ────────────────────────────────────────────────────────────────
# Short-term max RMS (10 ms windows) after a K-weighting-like curve (high-pass
# 100 Hz + a +4 dB shelf above 1.5 kHz, where the ear is keenest), so a bright
# tick and a dull thunk level by how loud they SOUND, not by their peaks.
TARGET = {"move": -17.0, "bump": -18.5, "select": -14.5, "back": -16.5, "open": -15.5}


def loudness(x):
    k = biquad(biquad(x, "hp", 100), "hs", 1500, gain_db=4.0)
    w = n_(0.010)
    if len(k) < w:
        return 20 * np.log10(np.sqrt(np.mean(k * k)) + 1e-12)
    c = np.cumsum(np.concatenate([[0], k * k]))
    ms = (c[w:] - c[:-w]) / w
    return 10 * np.log10(ms.max() + 1e-12)


def level(x, cue):
    # real DC only: subtracting the mean put a short beep's own lopsidedness
    # (-37 dB under item-open) as an offset under the whole clip — a raised
    # tail and a step at the start
    x = biquad(x, "hp", 15)
    x = fade_tail(x)
    g = 10 ** ((TARGET[cue] - loudness(x)) / 20)
    x = x * g
    pk = np.abs(x).max()
    if pk > 0.89:                              # keep -1 dBFS headroom
        x *= 0.89 / pk
    return x


# ── the packs ───────────────────────────────────────────────────────────────
def pack_codec():
    """CODEC — the MGS codec call: band-limited square blips, crushed to 8-bit."""
    def blip(f, dur, tau, f_end=None, duty=0.5):
        fr = f if f_end is None else sweep(f, f_end, dur)
        return square(fr, dur, duty) * env_exp(dur, tau, attack=0.0004)

    def chip(x):
        return biquad(crush(x, 22050, 7), "lp", 7000)

    return {
        "move": chip(blip(1760, 0.045, 0.012, 1660, duty=0.25)),
        "bump": chip(at(0.09, (0, blip(196, 0.09, 0.022, 160)), (0, 0.6 * blip(147, 0.09, 0.02, 120)))),
        "select": chip(at(0.13,
                          (0.000, blip(1319, 0.045, 0.02)),
                          (0.045, blip(1976, 0.085, 0.03, duty=0.25)))),
        "back": chip(at(0.12,
                        (0.000, 0.9 * blip(1976, 0.04, 0.016, duty=0.25)),
                        (0.040, 0.9 * blip(1319, 0.08, 0.025)))),
        "open": chip(at(0.16, *[(i * 0.026, (0.75 + 0.08 * i) * blip(f, 0.07, 0.02, duty=0.25))
                                for i, f in enumerate([1319, 1661, 1976, 2637])])),
    }


def pack_garage():
    """GARAGE — the Armored Core hangar: relay clicks, servo whine, hydraulic hiss."""
    def click(scale=1.0, bright=1.0, dur=0.05):
        body = sine(sweep(170 * scale, 110 * scale, dur), dur) * env_exp(dur, 0.006)
        ring = modes(dur, [(1870 * scale * bright, 1.0, 0.010), (3120 * scale * bright, 0.7, 0.007),
                           (4410 * scale * bright, 0.45, 0.005), (6230 * scale * bright, 0.3, 0.003)])
        snap = biquad(noise(dur) * env_exp(dur, 0.0009, attack=0.0001), "hp", 2500)
        return 0.9 * body + 0.35 * ring + 0.8 * snap

    def servo(f0, f1, dur, peak):
        fr = sweep(f0, f1, dur)
        buzz = square(fr, dur, 0.3) + 0.5 * square(fr * 2.01, dur, 0.5)
        return biquad(biquad(buzz, "bp", 1600, q=0.9), "lp", 4000) * env_bell(dur, peak, dur * 0.35)

    hiss = biquad(biquad(noise(0.28), "bp", 5200, q=0.8), "hp", 2500) * env_bell(0.28, 0.05, 0.07)
    return {
        "move": click(),
        "bump": biquad(click(scale=0.62, bright=0.7, dur=0.07), "lp", 2600),
        "select": at(0.2, (0, click()), (0.038, 1.25 * click(scale=0.8)),
                     (0.045, 0.16 * servo(700, 1500, 0.15, 0.06))),
        "back": at(0.17, (0, 0.16 * servo(1300, 560, 0.12, 0.03)), (0.10, click(scale=0.85))),
        "open": at(0.32, (0, click(scale=0.9)), (0.012, 0.55 * hiss)),
    }


def pack_tick():
    """TICK — barely there: soft wooden ticks, the least tiring to hear all night."""
    def tock(f, dur, tau, body=0.0):
        x = modes(dur, [(f, 1.0, tau), (f * 2.02, 0.25, tau * 0.6)], ph=0.0)
        if body:
            x += body * sine(f * 0.46, dur) * env_exp(dur, tau * 1.4)
        tr = biquad(noise(dur) * env_exp(dur, 0.0006, attack=0.0001), "lp", 5000)
        return biquad(x * env_exp(dur, 1.0, attack=0.0006) + 0.25 * tr, "lp", 7000)

    return {
        "move": tock(2200, 0.03, 0.0045),
        "bump": tock(900, 0.04, 0.007),
        "select": tock(1300, 0.07, 0.016, body=0.6),
        "back": tock(1000, 0.06, 0.012, body=0.5),
        "open": sine(sweep(900, 1600, 0.06), 0.06) * env_bell(0.06, 0.012, 0.016),
    }


def pack_scanner():
    """SCANNER — the HUD's lock-on: clean sine beeps with a radar shimmer."""
    def beep(f, dur, tau, vib=0.0, f_end=None):
        fr = f if f_end is None else sweep(f, f_end, dur)
        if vib:
            fr = np.asarray(fr, float) * (1 + vib * np.sin(2 * np.pi * 42 * t_(dur)))
        return sine(fr, dur) * env_exp(dur, tau, attack=0.0012)

    deny = sine(330, 0.08) * (0.6 + 0.4 * np.sign(np.sin(2 * np.pi * 50 * t_(0.08)))) * env_exp(0.08, 0.03)
    return {
        "move": beep(2637, 0.045, 0.014, vib=0.012),
        "bump": biquad(deny + 0.4 * square(165, 0.08) * env_exp(0.08, 0.02), "lp", 2200),
        "select": at(0.12, (0, beep(2093, 0.035, 0.012)), (0.045, beep(2793, 0.07, 0.022))),
        "back": beep(2400, 0.08, 0.035, f_end=1200),
        "open": room(beep(1200, 0.1, 0.05, vib=0.018, f_end=2800), wet=0.22, size=0.7, tail=0.12),
    }


def pack_psx():
    """PSX — a warm FM chime with a little room, the 32-bit console menu."""
    C5, E5, G5, C6, E6, G6 = 523.25, 659.26, 783.99, 1046.5, 1318.5, 1568.0

    def bell(f, dur=0.16, tau=0.045, idx=2.2):
        return fm(f, 3.5, idx, dur, tau, tau * 0.5) + 0.3 * fm(f * 2, 1.0, 0.8, dur, tau * 0.6, tau * 0.3)

    wood = fm(600, 1.41, 3.0, 0.06, 0.012, 0.005)
    return {
        "move": room(bell(C6, 0.12, 0.03), wet=0.12, size=0.8, tail=0.12),
        "bump": room(wood, wet=0.08, size=0.7, tail=0.08),
        "select": room(at(0.28, (0, bell(C6, 0.25, 0.08)), (0.035, 0.8 * bell(G6, 0.24, 0.08))), wet=0.2),
        "back": room(at(0.22, (0, 0.8 * bell(G5, 0.2, 0.06)), (0.04, bell(C5, 0.18, 0.06))), wet=0.18),
        "open": room(at(0.3, *[(i * 0.035, (0.7 + 0.1 * i) * bell(f, 0.2, 0.06)) for i, f in enumerate([C6, E6, G6])]),
                     wet=0.2),
    }


def pack_glass():
    """GLASS — struck glass, inharmonic and bright: the menu-glass family, as a sound."""
    def tap(f, dur=0.14, tau=0.04, gain=1.0):
        x = modes(dur, [(f, 1.0, tau), (f * 2.32, 0.5, tau * 0.7), (f * 4.25, 0.3, tau * 0.45),
                        (f * 6.63, 0.18, tau * 0.3)])
        tr = biquad(noise(dur) * env_exp(dur, 0.0005, attack=0.0001), "hp", 6000)
        return gain * (x + 0.2 * tr)

    return {
        "move": room(tap(2800, 0.09, 0.022), wet=0.1, size=0.6, tail=0.08),
        "bump": biquad(tap(1100, 0.08, 0.012), "lp", 3000),
        "select": room(at(0.22, (0, tap(2350)), (0.04, tap(3520, gain=0.8))), wet=0.16, size=0.7),
        "back": room(at(0.2, (0, tap(3150, gain=0.7)), (0.04, tap(2100))), wet=0.14, size=0.7),
        "open": room(at(0.26, *[(i * 0.03, tap(f, gain=0.8)) for i, f in enumerate([2100, 2800, 3730])]),
                     wet=0.18, size=0.7),
    }


def decode(path):
    """An audio file → mono float at SR, through the pinned ffmpeg (or the system's)."""
    import shutil
    import subprocess
    ff = Path.home() / "deps/ffmpeg-n8.1-static/bin/ffmpeg"
    ff = str(ff) if ff.exists() else (shutil.which("ffmpeg") or "ffmpeg")
    raw = subprocess.run([ff, "-v", "error", "-i", str(path), "-ac", "1", "-ar", str(SR),
                          "-f", "s16le", "-"], check=True, capture_output=True).stdout
    return np.frombuffer(raw, "<i2") / 32768.0


def trim(x, cap=None, fade=0.2):
    """Cut an MP3's lead-in (encoder delay + padding: ~50 ms of nothing, which
    would make every press feel late) to 1 ms before the sound starts, and cap a
    long ring at `cap` seconds with a `fade`-second fade-out."""
    pk = np.abs(x).max()
    i = max(0, int(np.argmax(np.abs(x) > pk * 0.01)) - n_(0.001))
    x = x[i:].copy()
    tail = int(len(x) - np.argmax(np.abs(x[::-1]) > pk * 0.003))
    x = x[:tail]
    if cap and len(x) > n_(cap):
        x = x[: n_(cap)]
        k = n_(fade)
        x[-k:] *= np.linspace(1, 0, k) ** 2
    return x


def first_beep(x, floor_db=-60.0):
    """Keep only the first beep of a clip that repeats itself (an echo): cut at
    the first 5 ms window after the peak that falls `floor_db` below it."""
    w = n_(0.005)
    pk = np.abs(x).max()
    start = int(np.argmax(np.abs(x))) // w * w
    for i in range(start, len(x) - w, w):
        if np.sqrt(np.mean(x[i:i + w] ** 2)) < pk * 10 ** (floor_db / 20):
            return fade_tail(x[: i + w], 3.0)
    return x


MGS_FROM = None   # --mgs-from: a person's own copies of the clips


def pack_mgs():
    """MGS — Metal Gear Solid's own menu sounds (source-assets/sfx/mgs/, the author's
    picks). Not synthesised: decoded, trimmed and levelled like the rest.
    They're Konami's, so a public codec doesn't carry them: someone with their
    own copies builds the pack into their own folder (--mgs-from)."""
    src = MGS_FROM or OUT.parent.parent / "source-assets" / "sfx" / "mgs"
    if not (src / "item-equip.mp3").exists():
        return None                            # no sources here (the laptop) — keep the baked WAVs
    equip = trim(decode(src / "item-equip.mp3"))
    # bump: the equip blip a fifth down, dulled — "that's the end" in the same voice
    idx = np.arange(0, len(equip) - 1, 2 / 3)
    low = np.interp(idx, np.arange(len(equip)), equip)
    return {
        "move": equip,
        "bump": biquad(low, "lp", 3000),
        # select = the item menu opening (the author, 2026-10-15: "the one that plays on
        # continue open"); codec-open and item-used are spare
        # — its first beep only: the repeats read as an echo (the author, same night)
        "select": first_beep(trim(decode(src / "item-open.mp3"))),
        # back = codec-close without the 145 ms burst of static it opens on — the
        # tone, its ring and the hiss under it stay as they are (the author's pick from
        # an A/B, 2026-10-15; cut-shorter and de-hissed takes read worse)
        "back": trim(fade_head(trim(decode(src / "codec-close.mp3"))[n_(0.146):]), cap=0.85),
        # open = the same single beep (the CONTINUE deck still had the echo)
        "open": first_beep(trim(decode(src / "item-open.mp3"))),
    }


PACKS = {
    "mgs": pack_mgs,
    "codec": pack_codec,
    "garage": pack_garage,
    "tick": pack_tick,
    "scanner": pack_scanner,
    "psx": pack_psx,
    "glass": pack_glass,
}
CUES = ["move", "bump", "select", "back", "open"]


def write_wav(path, x):
    pcm = np.clip(np.round(x * 32767), -32768, 32767).astype("<i2")
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


def main(argv):
    """codec_sfx_forge.py [pack …]                       re-forge into assets/sfx/
    codec_sfx_forge.py --mgs-from <folder> [--to <dir>]  build the MGS pack from YOUR
        own item-equip.mp3, item-open.mp3 and codec-close.mp3 into ~/.local/share/
        codec/sfx/mgs/ (or --to), where codec finds it — it then appears in
        Settings ▸ SYSTEM and the garage editor's SOUND dial."""
    global OUT, MGS_FROM
    if "--mgs-from" in argv:
        MGS_FROM = Path(argv[argv.index("--mgs-from") + 1]).expanduser()
        OUT = (Path(argv[argv.index("--to") + 1]).expanduser() if "--to" in argv
               else Path.home() / ".local/share/codec/sfx")
        if not (MGS_FROM / "item-equip.mp3").exists():
            sys.exit(f"no item-equip.mp3 in {MGS_FROM} (also needs item-open.mp3, codec-close.mp3)")
        argv = ["mgs"]
    names = argv or list(PACKS)
    for name in names:
        if name not in PACKS:
            sys.exit(f"unknown pack {name!r} — have: {', '.join(PACKS)}")
        cues = PACKS[name]()
        if cues is None:
            print(f"{name:8s} (no sources here — kept the baked WAVs)")
            continue
        (OUT / name).mkdir(parents=True, exist_ok=True)
        for cue in CUES:
            x = level(np.asarray(cues[cue], float), cue)
            write_wav(OUT / name / f"{cue}.wav", x)
            print(f"{name:8s} {cue:6s} {len(x) / SR * 1000:5.0f} ms  "
                  f"loud {loudness(x):6.1f}  peak {20 * np.log10(np.abs(x).max()):5.1f} dBFS")


if __name__ == "__main__":
    main(sys.argv[1:])
