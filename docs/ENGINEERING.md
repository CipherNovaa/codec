# Engineering notes: hard problems, and what they turned out to be

codec's hardest bugs rarely matched their first explanation. These are
the ones worth telling: what was seen, what was really wrong, what changed,
and how it was proven. The rule that runs through all of them: **measure on
the real device, and trust the picture over the telemetry.**

**Contents:**
[The buffer that shrank towards the end of the film](#1-the-buffer-that-shrank-towards-the-end-of-the-film) ·
[Dolby Vision at full bitrate over marginal wifi](#2-dolby-vision-at-full-bitrate-over-marginal-wifi) ·
[The "HDR bug" that was a phone's decoder](#3-the-hdr-bug-that-was-a-phones-decoder) ·
[A flicker only codec caused](#4-a-flicker-only-codec-caused) ·
[A 1.4-second stall from a sound effect](#5-a-14-second-stall-from-a-sound-effect) ·
[Locking a server that trusted everyone](#6-locking-a-server-that-trusted-everyone) ·
[Subtitles 9.7 seconds late](#7-subtitles-97-seconds-late) ·
[A dependency upgrade that silently slowed every party cast](#8-a-dependency-upgrade-that-silently-slowed-every-party-cast) ·
[The cursor that wouldn't hide over HDR](#9-the-cursor-that-wouldnt-hide-over-hdr) ·
[How it's checked](#how-its-checked)

---

## 1. The buffer that shrank towards the end of the film

**Seen:** a Dolby Vision cast played perfectly for an hour, then began to
buffer, more and more often as the film went on.

**What it was:** the DV lane serves one static DASH manifest when the cast
starts. At that moment the muxer has produced only one to three segments, so
the manifest's timeline for the *rest of the film* was filled with the
average of those first few segments. They happened to be 0.4 % shorter than
the film's true mean, and 0.4 % compounds: by hour two the manifest was **31
seconds** ahead of the real stream. The player judges "have I buffered enough?"
from the manifest's clock, so it thought it was further ahead than it was, and
its real cushion shrank until it ran dry.

**Found by** tabulating the receiver's own debug beacon (real buffered
seconds, estimated bandwidth, segments fetched per 20 s) against film
position, and seeing the real cushion fall linearly while the player
believed it was steady.

**Fix:** the timeline's tail is now an even fill of the film's remaining
length at the encoder's nominal segment size, with the count floored so it
never over-advertises, and the last entry absorbs the remainder so the total
is exact. Once a title has been muxed whole, its real per-segment durations
are stored and used from then on.

**Proven:** the same film, cast again, held its buffer at 19.8–21.8 s against
a goal of 20 for 25 minutes of playback, with zero rebuffering. A unit test
builds a synthetic 859-segment film and checks the count never exceeds reality
and drift stays under two seconds.

## 2. Dolby Vision at full bitrate over marginal wifi

**Seen:** DV casts stuttered and froze on movie nights. The constraints were
strict: full source bitrate (no transcode, no quality cut), the existing wifi,
and every Cast feature kept.

**What it was:** not throughput. Steady-state playback was fine. The enemy was
a ~20-second startup stall plus **per-segment bitrate peaks against a thin
buffer**. Most of the library's DV encodes use 10-second GOPs, so each DASH
segment is one GOP, 40–150 MB, peaking near 120 Mbps, and the Cast receiver's
default ~10-second buffer held exactly one segment. Every fetch had to beat
real time, or the picture stopped.

**Fix:** the Cast framework exposes no setting for its player's buffer, but it
merges a custom player config after its own defaults. The DV lane now asks for
a deeper forward buffer with parallel segment prefetch, and the segments were
cut into ~2-second pieces so they can be fetched in parallel across TCP stalls.
The buffer is sized per film from its bitrate: a 130 MiB budget, 16 to 60
seconds, because the TV's media buffer tops out near 165 MB; it backs off if
the TV ever reports it full. The HDR10 and SDR lanes keep the defaults: they race a live encoder
and would ask for segments that don't exist yet. A seek micro-stutter that
appeared afterwards was traced to the resume threshold and tuned
(`autoResumeDuration`).

**Proven:** all 24 Dolby Vision titles in the library play at full bitrate
(the worst at 53 Mbps), start in 0–8 s instead of ~20, and seek cleanly. A
sweep of the other 139 titles found and fixed two unrelated bugs on the way:
8-bit HEVC sources hitting a hardcoded 10-bit pixel format, and a hardware
decoder rejecting one 1440×1080 source (now a CPU-decode fallback).

## 3. The "HDR bug" that was a phone's decoder

**Seen:** a watch-party guest's budget phone flickered on HDR10 films but
played SDR films fine. Everyone's first guess, including ours: the
HDR-to-SDR tone mapping.

**What it was:** the tone mapping was cleared first. The same 90 seconds run
through the exact pipeline with and without the suspect option gave
bit-identical frames. The real pattern: the wide 4K films happen to be the HDR
ones, and a scope 4K film's "1080p" rung is actually **2542×1080, H.264 level
5.0**. The guest page capped phones by *height* only, so it allowed that rung,
and the phone's hardware decoder couldn't take it: it fell back to software,
showing about 7 frames a second. Worse, the page rebuilt the whole player on
any video error, so each failure blanked the screen: the "flicker".

**Fix:** each rung is now checked with the browser's own `decodingInfo`
before it's allowed; a frames-shown watcher steps down when a rung can't keep
up; a second decode error on a rung within two minutes rules it out; rebuilds
are rate-limited; and the page reports what it decided (`lh/dc/rb` beacons).
Each guest now climbs only as high as their device actually decodes.

**Side find:** the same log review showed party tokens leaking through the
edge proxy's `Referer` logging. That's now filtered, and the old tokens were
scrubbed.

## 4. A flicker only codec caused

**Seen:** "is something flickering the screen? It only happens on codec."

**What it was:** a performance pass had taught codec to stop drawing when
nothing changes, so an idle screen sat at about **1 frame a second**. With
FreeSync engaged for fullscreen windows, the monitor followed that, far below
its 48 Hz floor, and a VA panel's brightness swings at refresh extremes. The
optimisation was correct; the display couldn't take it.

**Fix:** codec watches whether adaptive sync is running on its display and,
only then and only while no film plays (a film sets its own steady rate),
keeps presenting every refresh with a near-invisible tick. Along the way: Qt
had silently chosen its basic render loop, which animates off a ~60 Hz timer
on a 170 Hz panel. A FRAME RATE setting now picks the threaded loop by default
(170 fps menus), with the 60 Hz loop as the frugal option, measured for CPU
cost on both.

## 5. A 1.4-second stall from a sound effect

**Seen:** after UI sounds landed, the first screen dropped clicks: "codec lags
at startup".

**What it was:** Qt Multimedia. Its first call to find the default audio
output loads Qt's FFmpeg media backend *on the GUI thread*: a **1.4-second
stall**, plus a GPU probe that pulled in CUDA and the NVIDIA video decoder,
**+130 MB** of memory, to play five tiny WAV files.

**Fix:** a small mixer of codec's own (12 voices, pitch jitter, constant-power
pan) feeding **one native PipeWire stream**, connected after launch and paused
while silent. Each event-loop turn plays only its strongest cue, so a held key
or a burst of changes never stacks into a buzz. Memory back to baseline,
start-up clean. Qt Multimedia is now banned from the codebase.

## 6. Locking a server that trusted everyone

**Seen:** an audit before going public. The hub served the whole library to
its own house with no authentication, which was fine for one house and wrong
for anyone else's network.

**What it was** was worse than missing auth: every response carried
`Access-Control-Allow-Origin: *`, and POST bodies were parsed as JSON whatever
their content type. So **any web page open in any browser on the network**
could have asked the hub for its internet browse token and read the answer.

**Fix:** a gate in front of every private request:

- the `Host` must be one of the hub's own names (against DNS rebinding)
- a foreign web origin gets media files only, never controls or writes
- devices pair with an on-screen "WANTS TO JOIN · ⏎ ALLOW"; keys are stored
  only as SHA-256 hashes, in 0600 files
- a network can be marked trusted, so nothing changed for the house it grew up in

The public port was already narrow: token-scoped, read-only, and addressed by
**integer library index, never a path**. That invariant held through two
full audits.

**Proven:** a throwaway server driven from another LAN address through every
case (unpaired, paired, foreign origin, rebinding Host, TV while casting, party
link), then a real cast, the TV remote and a party on the live hub.

## 7. Subtitles 9.7 seconds late

**Seen:** fetched subtitles that were right for the film but wrong in time:
one was 9.7 seconds late from the first line.

**What it was:** subtitle releases are timed against *a* master of the film,
not necessarily yours. A different cut, a different studio logo, a PAL
speed-up, and every line drifts.

**Fix:** every fetched subtitle is re-timed against the film's own audio
(ffsubsync, on a queue on the hub, after any live cast lane so it never
competes with playback); the raw file is kept. The fetcher also judges every
provider's candidates on the right film (by title), the right episode (out of
a season pack), the film's runtime and clean text, and fetches a sidecar
while a film is already casting, with no restart.

## 8. A dependency upgrade that silently slowed every party cast

**Seen:** party casts of HDR10 films that used to run at well over real time
suddenly crawled at about 1.2×, with no error anywhere.

**What it was:** a system FFmpeg upgrade (9.0) broke the zero-copy
Vulkan → libplacebo tone-mapping path. FFmpeg quietly fell back to a slow one.

**Fix:** codec pins a static FFmpeg 8 build, with a self-healing setup script,
and warns loudly when it finds itself on the system one. The pin stays until
the platform ships a libplacebo and FFmpeg pair that work together again.

## 9. The cursor that wouldn't hide over HDR

**Seen:** the pointer hid over SDR films but stayed on screen over HDR ones.

**What it was:** engaging HDR recreates the window, and the compositor hands a
new surface the pointer only when the pointer *moves*. codec had hidden a
cursor that no longer belonged to it.

**Fix:** after HDR engages, codec moves the pointer to exactly where it
already is. No visible motion, but the new surface now owns it, and it hides.

---

## How it's checked

- **The picture is the truth.** Telemetry lied more than once: a harness
  reported "smooth, zero errors" while a real 40-minute watch was 22 %
  buffering; the TV's `hdrType` reports SDR while HDR is engaged. Casts are
  judged by eye and by the receiver's own dropped-frame and buffering counts;
  HDR by the TV's compositor (`BT2020_ITU_PQ` layers), Dolby Vision by the
  bytes served (`dvh1.08.06`, the `dvvC` box, the RPU).
- **Every view has an offscreen render** at every screen size, from a sandbox
  that can't touch the real session (`tools/shots/`).
- **The receiver has a headless preview** of every state at the TV's own
  canvas (`tools/rx-preview/`).
- **A frame meter** (`CODEC_FPS=1`) measures before and after any UI change.
  Home's selection went from ~4.5 ms to ~1.4 ms; first frame from ~2.85 s to
  ~1.8 s.
- **Audits**: a 146-finding pass and a 104-finding pass across the codebase,
  fixed and verified, the security invariant re-checked each time.
- **Python tests** pin the trickiest logic: the DV timeline, party seats,
  subtitle judging and re-timing, YouTube parsing.
