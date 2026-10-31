# Watch party

**Send one link. Everyone watches the same frame.** A watch party puts the film
playing on your codec in front of friends anywhere: on their laptop, their
phone, or their television, in sync with you, with chat on screen.

## Starting one

1. Play something. Press **`w`** → **START WATCH PARTY**.
2. Copy the invite (**`⏎`** in the overlay) and send it however you like. In
   most chat apps the link unfurls into the film's poster and logo with a live
   badge.
3. Your friends open it. They land in **codec's web player**, in codec's own
   face, already on your frame. Nothing to install, no account.

Play, pause and seek from your codec and every screen follows. Press **`w`**
again to see who's there, and **`x`** to end the party for everyone.

## What your guests get

- **The web player**: the same dock as the app, the film's title logo, the
  synopsis decoding, chat in the corner. Keyboard, a TV remote or a gamepad all
  work.
- **Their own TV**: from the web player, guests on Chrome can cast to their
  television. The TV runs codec's receiver ([CAST-RECEIVER.md](CAST-RECEIVER.md))
  and holds the sync itself, so the phone can sleep. A 4K TV gets 4K, HDR10 or
  Dolby Vision when the link can carry it.
- **The best picture their device can play.** Each guest climbs the quality
  ladder only as high as their device actually decodes; a budget phone gets a
  stream it can play smoothly, a 4K television the full picture.
- **Guests in your house** are offered **PLAY DIRECT · LAN**, the full-quality
  stream straight from the hub without the internet in between.

## Running the room

- **Seats.** Everyone shows as present, seated or joining, with a ping dot.
- **Lock the room** once everyone's in; **drop** a guest; a dropped guest can
  ask to come back.
- **Changing films** holds every screen on "Loading for everyone" until all of
  them have it, then starts them together.
- **The end of a queue** shows "That's the end · waiting for the host".
- **When everyone leaves**, the party pauses itself, and it expires after six
  idle hours.

## What the hub needs

The invite has to reach your hub from the internet, through one of two routes:

| Route | Setup | Good for |
|---|---|---|
| **Tailscale Funnel** | `tailscale funnel --bg 8299` on the hub (below) | Getting started. A relay, about 16 Mbps shared, so 1080p |
| **A fast road** | Your own name (e.g. free DuckDNS) + Caddy in front of `127.0.0.1:8299` | 4K, HDR and Dolby Vision for guests' TVs |

Either way, **only the read-only, token-scoped party surface is exposed**: one
party's stream for whoever holds that party's link. Your library, your
controls and the hub's private port never leave the house.

---

# Engineering notes

How the party works and how it grew. Earlier sections describe the version they
are dated with; later sections supersede them where they disagree.

## How it works (the short version)

- **The stream** comes from *your* hub. codec's existing HLS lane (H.264 + AAC)
  is exactly what a Chromecast plays, so the TV pulls the movie straight from the
  hub — you don't send them a file.
- **The sync** is a tiny clock the hub publishes at `/p/<token>/state`: your
  position, paused/playing, and the hub's own timestamp. The TV computes the
  right spot in *hub time* (so the two houses' clocks never have to agree) and
  nudges out drift with a small seek.
- **The bridge** across the internet is **Tailscale Funnel**, which gives your
  hub a public `https://…ts.net` address. Only a **separate, read-only,
  token-scoped surface** (loopback `:8299`) is exposed there — never your `:8200`
  library. A leaked invite token can *watch that one party's stream*; it can't
  browse your library and can't drive your playback (writes stay on the LAN).
  A session pauses itself when the last viewer leaves and expires after six
  idle hours.

Requirements on the other end: a **Chromecast-capable TV** (Chromecast built-in /
Google TV / Android TV) or a ~$30 Chromecast, and an **Android phone with Chrome**
(iOS Safari/Chrome can't drive Cast from the web — Apple's restriction). If no
cast device shows up, a plain **Chromecast stick** is the fix.

## One-time setup

### 1. Tailscale Funnel (gives the invite link)

Tailscale is already installed and logged in on the hub. Funnel just needs turning
on for the tailnet, then pointed at the party surface:

```
# in the Tailscale admin console (one time): enable HTTPS certificates and Funnel
#   Settings → Feature previews → HTTPS + Funnel, and add the "funnel" node attr
tailscale funnel --bg 8299
tailscale funnel status      # should show https://<machine>.<tailnet>.ts.net → 127.0.0.1:8299
```

Once this is on, START WATCH PARTY shows a real `https://…ts.net/p/<token>` link.
Without it, the party still runs but there's no public link (the toast says so).

### 2. The Cast receiver

codec ships with a public Cast receiver, so a guest's TV runs codec's face with
no setup. To host your own, see [CAST-RECEIVER.md](CAST-RECEIVER.md).

### 3. Watch

1. Play a movie. Press **`w`** → **START WATCH PARTY**.
2. **Copy the link** (`⏎` in the overlay) and paste it to your watch buddy — a
   voice-chat message, a text, whatever.
3. They open it on their phone → **Cast** → pick their TV. The overlay shows
   **OTHER SCREENS · 1 CONNECTED** once they join.
4. Play, pause, seek — every screen follows. Press **`w`** again → **x** to end
   it for everyone (or just close codec; the session keeps running for them).

### Or: watch in a browser (no Cast device)

Append **`/watch`** to the invite link (`…/p/<token>/watch`) and open it in any
modern browser — a laptop, a smart-TV browser, or the **PS5's** hidden WebKit
browser. It plays the same synced HLS in a `<video>`, no Chromecast needed.

- **Subtitles**: any text subtitle track embedded in the movie is offered. Tap the
  **`CC`** button (or press **`c`**) to cycle tracks; captions are rendered by codec
  itself, so they line up the same on every browser. The first toggle is instant —
  the hub warms the English track when the party starts.
- **On-screen controls**: a control bar (bottom-right, auto-hides) gives **`CC`**,
  **screen-fit**, and **fullscreen** — so a TV remote or a PS5 pad works with no
  keyboard. Keyboard `c` / `z` / `f` do the same where a keyboard exists.

## One clock, any number of screens

**The session lives on the hub, not in the app that started it.** That one
decision is what makes the rest work: your own TV can be a viewer instead of the
projector, two screens can hold the same moment, and closing codec doesn't end
anybody else's night.

Pressing **`w` → START** mints a hub session from what you're watching and joins
it — no reload, no black frame, the file is already open at the right spot. From
then on this screen is a follower like everyone else, and space / arrows move
**every** screen at once.

Or drive it from the shell with no app running at all:

```bash
codec_party.py start "children of men"   # prints the invite link
codec_party.py play                      # drive the clock
codec_party.py pause
codec_party.py seek 1:23:00              # absolute (or plain seconds)
codec_party.py skip -30                  # relative, like a remote
codec_party.py status
codec_party.py stop
```

The clock is derived from `(position at epoch, rate, paused)`, so there's no
timer to drift and it survives a hub restart.

### Joining from another codec

Any codec on the network sees the session — a chip in the header reads
**`● PARTY · CHILDREN OF MEN 27:14 · 2 WATCHING`**. Press **`w`** (or click the
chip) for **JOIN**, the invite link, and **END FOR EVERYONE**.

Joining plays **your own copy off the shelf**, slaved to the hub clock: full
quality, no transcode, and nothing but a few hundred bytes of clock crossing the
network. Measured against a live session it holds **0.0–0.1 s** and lands exactly
on a seek — where the TV over Funnel sits ~5 s back, because it's pulling HLS
across the internet. A machine that doesn't have the file streams instead.

Sync is done by nudging playback speed a few percent, never by micro-seeking: a
seek throws away the buffer and, on a thin link, starves the very gap it was
trying to close. mpv pitch-corrects, so you can't hear it.

**How far apart screens actually sit.** Every follower deliberately plays a
little behind the hub clock, because sitting further back means more
already-delivered video ahead of the playhead — which is what survives a late
segment on a phone. That cushion scales to the measured round trip
(0.25s + 3x RTT), so a viewer on the LAN gets almost none and a phone on
cellular gets real protection. Measured desktop-vs-browser on the LAN: **0.4s**.
A codec playing its own file sits on the clock exactly.

### Who's in the room

Each follower measures its own round trip to the hub and sends it with the
clock poll — only the client can time that. The roster lists one viewer per
line with a dot for their link (green under 80ms, amber to 250, red past it);
tap a dot for the exact number, updating every second. Someone sitting on the
invite card without having pressed play shows as **not watching** and doesn't
count toward the room, so the clock doesn't keep rolling for an empty house.
**LEAVE** on the control bar stops watching without closing the tab or ending
anyone else's night.

### Seats: who gets a say (October 2026)

There are no accounts, so a stray invite link used to be as powerful as a
friend. A tab somebody forgot in the background counted as a viewer: its
buffering was half of a two-screen "majority" that froze the room, its cushion
could drag everyone 12 s back, and it kept an empty room rolling all night
while it pulled the stream over the hub's upload.

Now a screen has to earn a say, the only way possible without accounts: by
watching.

- **Present** — on the player, its tab in front, and (over the internet) a
  name typed on the invite card. Present screens count toward "N watching",
  set the cushion, and keep the room from auto-pausing. A tab hidden for 20 s,
  or someone sitting on the invite card, isn't present.
- **Seated** — present *and* playing in step with the room for a minute.
  Only seated screens can make the room **wait** for them or **vote** it back.
  A screen the room has waited on gives its seat up and earns it back, so the
  room never freezes twice in a row for the same link.
- **The house is trusted.** Anything on the LAN (this app, a TV the app
  joined, a browser at home) is seated the moment it's in step.
- **Still watching?** A guest tab hidden for ten minutes steps out of the room
  by itself and stops downloading; coming back says so and one tap rejoins.
- **A name first.** WATCH HERE and CAST TO TV both ask for a name; a guest's TV
  joins as *"Riley's TV"* and is let in as theirs.

The host's `w` panel shows each screen as IN THE ROOM / JOINING (with a meter
filling toward its seat) / AWAY / NOT WATCHING, and two controls:

- **DROP** (select a row, ⏎ twice) takes a screen out — its TV with it — and
  that screen can't come back.
- **LOCK ROOM** (`l`) lets nobody new in. Everyone already in the party,
  their TVs, and anything in the house still get in; a newcomer sees *"This
  watch party is locked"* (it lets them in by itself if the host reopens).

Someone determined can still script a seated guest; DROP + LOCK is the answer
to that. Seats handle the everyday case: forgotten tabs, second devices, and a
guest whose link can't keep up — they still watch (their screen catches itself
up), they just can't hold everyone else hostage.

### Staying level (0.9.21)

Nobody watches the hub. How close any one screen sits to the hub clock isn't
something a person in the room can perceive — what you feel is the **gap between
people**, a laugh or an "oh shit" arriving before the other person's picture
does. Being uniformly two seconds late is invisible. Being two seconds apart is
the only error that exists.

Aiming every screen at the hub as tightly as it individually can is what *makes*
that gap: the machine with the film on its own shelf lands dead on the clock, a
phone on cellular lands half a second back, and the half second between **them**
is the whole problem. So instead:

- **Every screen reports the cushion it needs** to play without stalling — a
  browser from its buffer depth and round trip, the app analytically (nothing to
  wait for on a local file), the TV by measuring how far behind it actually runs.
- **The hub publishes one cushion for the whole room**, the worst of them, and
  *everybody* plays at it — including the host on the fast machine, who is
  deliberately held back to stay level with the guest who can't be.
- **The cushion is nearly free.** It does not make the room sluggish: pause, seek
  and play are agreements about *which frame to be on*, so they land together
  whatever it is. All it changes is how far behind an invisible clock the film
  runs.
- **Attack fast, release slow** (0.15s per second). A link going bad pulls the
  room back within one poll; a single late reply doesn't yank it back and forth.

That last point is why a **Cast TV can now pull the room level with it.** A TV
sits seconds behind no matter what — HLS hands it whole segments and CAF exposes
no rate control to nudge it forward — so rather than leave it stranded, it
measures its own offset and everyone else drops back to meet it. Measured on the
real TV: it settled at hub −7.5s and the room lag settled at 7.51s, i.e. level to
within 10ms. Cap is 12s, so one broken screen can't drag the night off a cliff.

Two more things keep a room together:

- **Scheduled starts.** Play, seek and swapping the film all name a position
  *and* an instant ~0.9s out, so every screen holds the same frame and moves at
  once. Without it each screen started whenever its own poll happened to land —
  a stagger of up to a full poll, worse on a slow link, and nothing afterwards
  can undo the first second of it.
- **The room waits for a screen that has stopped.** A cushion keeps everyone
  level while video is still *arriving*; when someone's picture actually stops,
  the only way to stay together is to wait. Bounded hard: 4s of continuous
  stalling to trigger, 20s maximum wait, and 60s cooldown so one dying
  connection can't hold four people hostage. The overlay says who it's waiting
  for.

The `w` overlay shows the number and who set it — *"keeping everyone level 2.5s
back · Riley sets the pace"* — because a deliberate cushion with no explanation is
indistinguishable from a fault.

### When everyone leaves

A hub session has no publisher to lose, so nothing used to notice the room had
emptied — one played to nobody for hours after everyone went to bed. Now the
clock **stops when the last follower leaves**, at the position it held when they
left rather than wherever it wandered to, and the session ends on its own after
six idle hours. Pausing rather than ending means coming back is just play.

Ending is a write, so it only works from the LAN. A leaked invite link watches;
it can never end your session.

## 4K, HDR and the ladder (0.9.22)

Before this, every cast and every party got **one** stream: h264, SDR, one
resolution, one bitrate, chosen to suit the worst guest in the room. Two things
were wrong with that.

**HDR was not converted — it was mislabelled.** A PQ / BT.2020 source went
through `-pix_fmt yuv420p` and came out tagged BT.709. Nothing mapped the
curve or the primaries, so the TV displayed HDR values as if they were SDR:
grey blacks, flat highlights, drained colour. 103 films here are PQ HDR — every
4K title in the library — and all of them looked like that on any screen except
the desktop app. The fix is a real tone-map (libplacebo, BT.2390, the ITU's own
display mapping) for SDR sinks, and *carrying the PQ picture through untouched*
for sinks that can show it.

**One rendition can only ever be wrong for somebody.** So the hub now publishes
an **ABR ladder** — several renditions at once — and each screen picks its own
rung from measured throughput. Nothing on the hub decides anyone's quality.

```
#EXT-X-STREAM-INF:BANDWIDTH=10995000,RESOLUTION=3840x2076,VIDEO-RANGE=PQ,CODECS="hvc1.2.4.L153.B0,…"
#EXT-X-STREAM-INF:BANDWIDTH=5990000,RESOLUTION=1998x1080,VIDEO-RANGE=SDR,CODECS="avc1.64002A,…"
… 720p · 480p · 360p · 240p
```

The whole ladder comes out of **one ffmpeg**: one decode, one tone-map, split to
every rung. Separate processes per rung would cost 5× and thrash the card.

**`VIDEO-RANGE=PQ` is what switches a television into HDR mode.** Without that
line a perfectly good PQ rung is shown as SDR — which looks *worse* than the SDR
rung, because nothing tone-mapped it.

**Profile and level are pinned on the encoders**, not left to nvenc, because the
master playlist has to declare them and a declaration that doesn't match the
bytes is the classic silent ABR failure — the player reads `CODECS`, decides it
can't play the rung, and shows black with no error. (Measured: unpinned
`h264_nvenc` chose Main@4.2 while the hand-written string claimed High@4.0.)

### What each screen gets

| | what it reads |
|---|---|
| **Direct cast to a 4K HDR TV** | native 4K HDR + a 1080p HDR fallback. Nothing tone-mapped — that lane has one sink and it takes PQ. |
| **Watch party, an HDR film** | TWO ladders out of the one encode (`range=pq` / the SDR default): a PQ HEVC pair (native + 1080p) for the screens that show HDR, and the whole tone-mapped SDR h264 ladder — native height included — for everyone else. Nobody is offered a switch between ranges mid-film. |
| **Watch party, a Dolby Vision film** | a guest television that shows DV reads the room's **DV lane** (`/p/<tok>/hls/tv.mpd`): the film's own bits, copied, one shared muxer per room. See *Dolby Vision for the room* below. |
| **Browser / phone** | the SDR rungs, correctly tone-mapped; a browser that shows HDR (`dynamic-range: high` + HEVC PQ decode) reads the PQ master and falls back to SDR on stalls. |

A party ladder is deliberately **one ladder for the whole room**, not one per
guest: the session key includes the ladder's shape, so per-guest ladders would
mean an ffmpeg per guest. Nothing is lost — every rung is declared, so a screen
that can't decode the HDR rung simply never selects it.

### What a Cast receiver can actually play (2026-10-11)

The 2026-08-02 finding — "this receiver takes transport streams only, so there
is no route to HDR through Cast" — was wrong about the **television** and right
about the **load**. CAF reads HLS segments as MPEG-TS unless the LOAD says
`hlsSegmentFormat` / `hlsVideoSegmentFormat = FMP4`; set them and the Bravia
plays fMP4 HEVC PQ in real HDR (`BT2020_ITU_PQ` on the SurfaceFlinger layer).

What a television in a party reads today:

| film | the TV reads | how |
|---|---|---|
| SDR | the ladder's h264 rungs, ≤ 1080p | HLS fMP4 |
| HDR10 | the PQ pair (native HEVC PQ + 1080p) | **DASH** — a static MPD the hub writes over the very same segments (`party_tv_mpd`). CAF's fMP4-HLS player cannot be put down at the room's moment (it reads the ends of the list first and numbers a live window by the wall clock); DASH states an absolute timeline. Every party fMP4 segment goes out restamped to absolute film time (`_party_abs_tfdt`) for every reader. |
| Dolby Vision (profile 8.1, regular GOP) | the room's DV lane | DASH, the solo DV lane's own machinery under a party-owned session |

A television is never offered h264 above 1080p (its h264 decoder's ceiling);
the 4K SDR rung is for browsers and 4K SDR monitors.

### Dolby Vision for the room

`/p/<tok>/hls/tv.mpd?g=<set>` is the solo DV copy lane (`_dv_lane_manifest`)
under a party-owned key (`partytv|<tok>|<src>|<aidx>|dv`): ONE muxer per room,
its start chosen by the hub a minute behind the room, exempt both ways from the
one-muxer rule (it never stops the host's own cast, a solo cast never stops it),
reaped with the party. Three things the solo lane never needed:

- **Each set's first segment starts clean.** The muxer's `seg1` is only the
  first segment for the first set; a later set joins mid-run, and a room seek
  is a native seek on this lane. The hub names each set on its segment URLs
  (`g`) and judges contiguity per set: a first fetch, or a jump, is served from
  its keyframe with the leading RASL pictures stripped (`dv_fix_seg1_rasl`) —
  the same tear a mid-film resume used to show.
- **A run the TVs watch.** `/state` carries `tv:{dv, gen, warm}`. A rewind
  past the run's floor re-warms the muxer behind the room — a new run, new
  numbering — and `gen` moves, so every set reloads the manifest; a set that
  sees the room before `warm` reloads too, and the hub re-warms. A film change
  starts the TV's party LOAD over (`reloadParty`) so the lane is chosen again.
- **The muxer is paced.** A copy runs 20-50x realtime, and left alone reads the
  whole film in minutes beside the ladder's own read of the file — the
  two-reader fight that collapsed a lane in September. `_party_dv_govern`
  SIGSTOPs it 300 s ahead of the room, SIGCONTs at 180 s, on every fetch (by
  the first 30 s sweep it was already 750 s ahead).

A set the copy starves (20 s of buffering in its first three minutes) gives the
lane up for that cast and reads the ladder, where ABR steps down. The receiver
chooses DV (`is_dv_supported`) > PQ (`is_hdr_supported` + HEVC) > SDR.

Measured on the Bravia, 2026-10-11, *A Quiet Place* (3840x1600 DV 8.1): the
set joins mid-film and is seated within 20 s, holds −0.2…−0.6 s of the room
through a +120 s seek, a −200 s seek, a pause and a resume, 0 dropped frames,
`BT2020_ITU_PQ` on, `dvh1` + `dvvC` in the served init.

### The fast road: one link, two doors

Tailscale Funnel is a relay — ~16 Mbps for everyone outside, shared — and
that is the wall for 4K, HDR and a Dolby Vision television. The house also
answers at its own name, **`https://<name>.duckdns.org:8443`** (a free DuckDNS name): Caddy
(`config/Caddyfile.codec-edge`, user unit `codec-edge.service`) in front of
**`127.0.0.1:8299` only** — the same read-only, token-scoped, integer-keyed
surface Funnel exposes, never :8200, never a path. Its certificate comes over
DNS-01 (DuckDNS sets the TXT), so no inbound 80/443 is needed; the router
forwards 443 and 8443 to the hub's 8443. `codec-ddns.timer` keeps the name on
the WAN address, read off the router over NAT-PMP (`scripts/codec_ddns.py`).

The **invite stays the Funnel link** (og tags, `inviteUrl`, the receiver URL
all do). The guest page on the Funnel origin probes `DIRECT/p/<tok>/state`
(2.5 s, no id — a probe, not a screen) and, if it answers, moves itself there
before the guest taps anything, carrying `?n=&g=` so the room sees one person
who changed roads. It never hops a guest already watching, nor one on the
host's own Wi-Fi (they get PLAY DIRECT on the LAN). On the fast road, four
failed clock polls send the page back to Funnel with `?road=funnel`, which
stops it trying again that visit. The TV follows the page: `castLoad` streams
from `location.origin`, so a cast started on the fast road is a fast-road cast
(the receiver fetches cross-origin; the hub's `ACAO:*` + the :8299 preflight's
`Allow-Headers` cover it).

Config: `party.directBase` (the fast road; never derived from a request's
Host), `party.funnelBase` (overrides `tailscale status` — a test hub). A guest
arriving through the edge with a private address and `X-Codec-Edge: direct`
(a hairpinning router) is treated as at home.

### The ladder stays on the GPU (zero-copy)

libplacebo tone-maps in Vulkan memory and nvenc reads CUDA memory; ffmpeg can
hand frames across on the GPU (`hwupload=derive_device=cuda`, the Vulkan device
created with `disable_multiplane=1` — CUDA imports single-plane images only;
the decoder's own frames never import, so every leg goes through libplacebo
first). Without the hop every encoded frame crossed PCIe and the shorter SDR
rungs scaled on the CPU — that, not nvenc, was the ceiling: a 4K SDR rung
beside the PQ pair ran 1.34x off the host and 1.9x with the hop (h264 at p3,
same VMAF). So an HDR film's party ladder is now PQ [native, 1080] + SDR
[native … 240], eight nvenc sessions (the driver no longer caps them).

The hop fails per picture, not per box: a 3840x1600 DV title's decoded frames
refuse the import at native height in p010 (`CUDA_ERROR_INVALID_VALUE`) while
2160 lines, its 1080 rung and its 8-bit leg all pass. `cuda_hop_legs` probes
the real file, per leg, and a leg that can't hop downloads as before.

### Vulkan decode is the reason this is affordable

Tone-mapping runs on the GPU. With a CPU decoder every 4K frame has to cross the
PCIe bus to get there, and that upload **alone** drops a 4K HDR source to 1.11×
realtime before any encoding happens. Decoded straight into Vulkan
(`-hwaccel vulkan -hwaccel_output_format vulkan`) the frames are already where
libplacebo wants them.

| | steady state |
|---|---|
| 6-rung ladder, 4K HDR top, CPU decode | **0.95×** — falls behind, everyone stalls |
| 6-rung ladder, 4K HDR top, Vulkan decode | **2.14×** |
| direct cast, 2-rung HDR ladder | **2.41×** |

Probe with the filter you will actually run. A bare `hwdownload` fails with `-22`
that looks exactly like "no Vulkan decoder", and the download has to name the
format the Vulkan frames really are (`p010le` for 10-bit, **not** the source's
`yuv420p10le`) — getting that wrong reported "no Vulkan" on a box where it runs
at 4.4×.

⚠ Burning subtitles forces CPU filters, which drags frames back off the GPU. A
burn lane therefore decodes on the CPU by design, and a burn request drops the
HDR rung — there is no correct brightness for white text composited into a PQ
frame (at full code value it is a 1000-nit glare).

### Bandwidth, not resolution, is the knob

```bash
codec_speedtest.py          # measure it and write it down
codec_speedtest.py --show   # measure, print, change nothing
```

```jsonc
"party": { "uploadKbps": 25000 }   // optional: override the measurement
```

Measure rather than guess. This number decides whether a guest gets 1080p or
tops out at 480p, and a flat default was wrong here by a factor of six (the
guess said 25 Mbps; the line measures 152). `codec_speedtest.py` records
`party.uploadKbpsMeasured`; an explicit `party.uploadKbps` still wins.

It reports the **median** push rather than the peak — a peak is whatever the
nearest edge cache swallowed in one burst, and a ladder sized against a burst
is a ladder that buffers — and it drops the first push, which pays TCP
slow-start and TLS setup for everything after it.

That budget is divided by the number of guests (down to a floor of three), and
rungs above the result are dropped. One guest on a 25 Mbps upload gets the 4K
HDR rung; three guests get a ladder topping out at 1080p, automatically. There
is also `party.streamHeight` if you want a hard resolution ceiling, but it
defaults to 0 (native) — the budget is the honest constraint.

The old `party.streamHeight: 720` / `party.streamKbps: 2200` keys are **dead**
and ignored. They were the ceiling on a single rendition that had to suit the
worst guest, so they were set low on purpose; read as ladder ceilings they cap
everyone at 480p, which is worse than what they replaced.

The bottom rung matters as much as the top. Simulated against real link speeds,
a ladder whose floor was 900k stalled **every segment** on a 900 kbps line with
nothing lower to fall to; adding a 400k/240p rung took the same link to zero
stalls. The floor is what keeps a guest on hotel wifi watching at all, and it is
about 2% of the encode.

## The room talks (0.9.23)

Chat, reactions and vote-to-rewind, for the same reason the party exists at
all: two people in different cities watching the same frame have nothing to say
it *with*. It works on every screen that can already watch — the browser
follower, the app, and a phone that has cast to a TV (the film is on the
television, the talk is in your hand, which is where second-screen belongs).

**A guest speaks through the clock poll they are already making.** There is no
new endpoint and no POST from the public surface — `&say=`, `&react=` and
`&vote=` ride the once-a-second `/p/<token>/state` request that proves they are
in the room, and the reply carries back everything said since `&cs=<id>`. That
matters more than it looks:

- The public listener still answers **404 to every POST**, which is the
  invariant this feature was most likely to break. It does not.
- It is token-scoped by construction. A forged token cannot talk, because it
  cannot poll.
- The poll interval *is* the first rate limit, before the hub's own 1.2s
  per-guest gap.
- Identity has ridden this poll since presence was unified — a chat line is the
  same shape as a name.

The host types in the `w` overlay and speaks over the LAN write surface
(`POST /party/say`), the door that has never been reachable from outside the
house.

**Rendering is `textContent`, everywhere, always.** The hub strips control
characters and caps a line at 180 characters, but what makes markup harmless is
never handing it to an HTML parser — not escaping it well. Reactions are a
closed vocabulary the hub publishes, so that path cannot carry arbitrary text
at all.

**Vote to rewind** is a majority of the *watching* room — someone sitting on
the invite card has not missed the line, and counting them raises the bar for
the people who did. One vote in a room of one or two, two in a room of three or
four. A vote is live for 25 seconds. In hub mode the hub moves the clock 30
seconds back and says so; in app mode the app owns the position, so the hub
says it out loud instead and the host reads the same chat everyone else does.

The transcript is a ring of the last 60 lines and is **not** persisted: a room
that comes back after a hub restart should not resume last night's conversation.

⚠ **The Cast receiver does not render chat, deliberately.** Whoever cast to
that TV is holding the phone that did it, and that page has the whole
conversation on it. Putting text over someone else's film to save them looking
down is a worse trade, and the receiver is the one component that cannot be
tested without occupying a real television.

## Subtitles on a television (0.9.23)

They render now. Three faults kept them off the screen, and each one looked
exactly like the others — "the TV doesn't show subtitles" — so fixing any two
of them changed nothing visible.

**1. The subtitle never arrived.** Pulling a text track out of a container means
demuxing the whole file: measured at **195s for a 19.3 GiB 4K remux** with
nothing competing, and far worse during a party, when the ladder encoder is
reading the same disk. Worse, `extract_vtt` had no single-flight guard, so every
client that asked for an uncached track started *another* full demux — a
television retrying plus a browser plus the warm thread had **five concurrent
19 GiB reads of the same file**, each making the others slower (16 MB/s instead
of 82). Callers now wait on the first extract instead of racing it.

**2. A stopped party left its encoder running.** An encoder was only ever
stopped when another one started, so a session that ended kept reading the disk
— measured still going twelve minutes after `/party/stop` returned `ok`. That is
what turned a three-minute extract into a twenty-minute one. `hls_stop_all()`
now runs when a party ends.

**3. Nothing ever turned the subtitles ON.** This was the real one. A text track
— sideloaded as a Cast track *or* declared in the HLS master as an `EXT-X-MEDIA`
rendition — is only ever **offered**. Shaka, which is what CAF plays adaptive
streams with, keeps text hidden until something asks for it, and `DEFAULT=YES`
in a manifest is a hint about *which* track to pick, not an instruction to
display one. So the television fetched the WebVTT, listed the track, reported it
active, and drew nothing. The receiver now calls
`TextTracksManager.setActiveByIds()` on `PLAYER_LOAD_COMPLETE`, wrapped whole:
subtitles are worth having and they are not worth a black screen.

Subtitles are also **in the manifest** now rather than sideloaded — a
`#EXT-X-MEDIA:TYPE=SUBTITLES` rendition per ready track, with `SUBTITLES="subs"`
on every variant. That is the streaming format's own mechanism, so the
television's ordinary subtitle button drives it and every other HLS client gets
it for free. ⚠ Only **ready** tracks are declared, in the manifest and in the
Cast track list both: a manifest naming a rendition the player cannot fetch is a
manifest with a broken entry, and offering a subtitle you cannot deliver is
worse than offering none — it lands in the TV's own subtitle menu and silently
does nothing when switched on.

**Style is a setting, not a constant.** Settings ▸ OUTPUT has **CAST CAPTION
SIZE** (60 / 72 / 85 / 100 / 125%) and **CAST CAPTION BACKGROUND** (outlined or
boxed). The desktop writes them to `config.json`; the hub bakes them into the
receiver page when it serves it, so the choice is made once on the screen with a
keyboard and every television the house casts to obeys it. Defaults are **72%
and outlined** — 1.0 is Cast's own default and it is sized for accessibility,
not for a film, and a box lays a black bar across the bottom of every shot.

**One face (v1.41, 2026-10-12).** Every caption on the television now draws in
the receiver's own `#cap` overlay — the party follower's tracks, the browse
page's cast and the roaming ladder included, which used to be CAF text tracks in
CAF's own SANS layer (a second look at the same film, and one that could start
blank on a cold track). The style rides each LOAD in `customData.capStyle`
(font / colour / size / box — the CASTER's settings, so a laptop's choice reaches
the TV), and a change in Settings reaches a running cast at once over the sub
channel (`{style}`); the page-baked values are the fallback. A follower shows the
room's English track from the start (its session says so too, so the first SUBS
press on the remote is no longer dead), and switches ride the sub channel
(`{url}`), never `EDIT_TRACKS_INFO`. Burned lanes (a piped fallback, every
YouTube cast) wear the same face through the hub's `substyle` lane parameter, and
YouTube burns read the cleaned captions the party route always served. The
overlay retries a cold track's 503 itself, shows every cue live at once, and
decodes entities.

## One receiver, two kinds of cast (0.9.24)

Pressing `c` used to hand the television to **Google's Default Media Receiver**
(`CC1AD845`). It plays anything a Chromecast can play and none of it is ours:
the idle plate is a grey system-font card, the transport chrome is fixed, and
there is no way to tell it anything. Everything the party receiver grew — the
wordmark, the card that covers CAF's own app-name plate, the code that actually
*turns subtitles on* — existed on a page a direct cast never loaded.

Both now run the same page. `codec_cast.py` launches the registered App ID from
`config.json` (`party.castAppId`) instead of the default receiver.

**The thing that made this free was not obvious, and had to be measured.** A
registered receiver URL must be HTTPS, so the TV loads our page from the Funnel
— while the media URLs a direct cast builds are plain `http://` on the LAN. That
is mixed content, and modern Chromium blocks it outright; if this set did too,
every local cast would have had to travel out through Tailscale and back, at up
to `-maxrate 40M`, to reach a television two rooms away. **It doesn't.** Probed
on the Bravia 2026-08-02, and confirmed from the hub's own `hls-access.log`
rather than from a status message — the TV fetched the master, the rendition and
the segments, each request carrying `Origin=https`. Media still goes straight
across the LAN.

⚠ **Don't assume this of the next television.** It is a property of this set's
firmware, not of Cast. The probe is `scripts/` adjacent and worth repeating on
any new device: load one `http://` LAN URL and one `https://` Funnel URL into
the same receiver and see which plays.

**Amber solo, blue party.** The colour of the transport bar was the first thing
that told the host which mechanism they were on, and it did so by accident: our
receiver sets `cast-media-player { --theme-hue: 220 }` and Google's happens to
be amber. Routing both through one receiver would have collapsed that into a
single colour, so a solo load now sets `--theme-hue: 38` from `customData`. Same
tell, on purpose.

**What a solo cast shows.** No roster and no clock — there is one screen and one
viewer — but the rest holds: the wordmark card while nothing is playing, and a
small `CODEC` top-left with the film's name under it for a few seconds once it
starts, then out of the way. The mark begins as just `CODEC` and *earns* the
rest of itself: the receiver cannot know which kind of cast it is until the LOAD
arrives, so a page that opened saying `WATCH PARTY` would say it briefly on
every solo cast before correcting itself.

The name is **ours**, not CAF's. `cast-media-player` draws the title itself —
large, centred, in a system font — which put a second title in somebody else's
type next to our mark. It only draws what it is handed, so a solo LOAD hands it
an empty one and the name sits under the wordmark, sharing its left edge and
its rule: one separator, one alignment, two weights. ⚠ Emptied, **not
deleted**: with no metadata at all the player can fall back to the `contentId`,
and a URL across the screen is worse than the title it replaced.

**A film paused and left gets an information panel, not a cover.** After 2.5
seconds paused — long enough that pausing to catch a line of dialogue still
leaves the frame alone — the strip cross-fades out and a panel fades in:

```
CODEC
──────────────
[poster]   Children of Men (2006)
           dir. Alfonso Cuarón
           1H 49M · 1080P · AAC 5.1 · 7.6
           Science Fiction, Thriller
```

Two lines under the director, not one: what the **file** is — runtime,
resolution, dynamic range, soundtrack, score — is a row of instrument readings
and reads as one, small and spaced and uppercase; what the **film** is stays in
sentence case underneath, where it belongs to the title rather than to the
specs. A 4K HDR release reads `1H 51M · 4K · HDR · DTS 7.1 · 7.1`.

The frame you paused stays on screen and is the only backdrop this needs; the
scrim is opaque where the type sits and gone by the middle of the screen.
Everything but the soundtrack comes from the hub's own manifest
(`library_card()`) — the same `subtitle` string the library and detail page
show, so the television cannot disagree with the app about what a film is — and
the soundtrack comes from the probe that has always run (`audio_line()`). ⚠ It
names the **source** track, not what the lane is sending: a 7.1 TrueHD film is
a 7.1 TrueHD film even while this TV is being handed stereo AAC, because the
panel describes the film, not the plumbing. The poster is loaded at LOAD rather
than at pause, so it arrives finished instead of as an empty rectangle.

⚠ **`style.display = ''` does not show a hidden element.** `#ipost` is
`display:none` in the stylesheet, and setting the inline style to the empty
string *removes* it and hands the rule straight back to `none`. The poster was
resolved, fetched and assigned, and simply never drawn — with nothing anywhere
reporting a problem. Use `'block'`.

⚠ **The panel is on the LEFT, not along the bottom.** CAF draws its own
transport — playhead, seek bar, timer — across the bottom of a *paused* film,
which is exactly where a lower third wants to live. That same collision is what
moved the playing strip to the top corner in the first place.

A file that isn't in the library — a stray path, a YouTube video — simply gets
no panel and falls back to the plain wordmark card.

⚠ **A session's `src` is a URL for anything in the hub's tree, and a filesystem
path only for portable media outside it** (the lane wants a URL the hub can
fold back onto its root). The manifest stores URLs. Matching one against the
other with `realpath()` therefore compared a URL to a path, agreed exactly
never, and delivered the year and the artwork to the television as nothing at
all — with no error anywhere, because "not in the library" is a legitimate
answer. `_library_rel()` normalises both forms to one root-relative path.

⚠ **Cross-fade, not a class swap.** Going straight from the strip to the card
changed the layout while the element was still fully opaque, so the whole thing
arrived in a single frame and read as a jump cut. The strip fades out first
(~420ms), then the card fades in under its own transition.

**This also fixed a live bug.** `#room` paints from the first byte on purpose,
because CAF draws its own card in exactly those first seconds — but only
`paintRoom` ever took it back off, and `paintRoom` runs off the party clock
poll. Any cast without a party therefore wore a full-screen black scrim reading
`CODEC • WATCH PARTY` **over the entire film**. That hit the phone remote's
solo-cast path from the moment the overlay landed.

⚠ **The worker was installed as a copy, not a symlink.** The app runs
`~/.local/bin/codec_cast.py`; that file was a copy taken on 19 July and had been
**seven commits behind the repo for two weeks**, so cast fixes landed in git and
never reached the running app. It is a symlink now, like `codec_serve.py` always
was, and `codec_selfcheck.py` asserts it.

The registered app is still named *codec watch party* in the Cast console, which
is what the device picker and CAF's own idle card display. Renaming it to
**CODEC** at cast.google.com/publish would read correctly for both kinds of cast
— a one-field edit, no re-registration.

## The party face on a television (2026-10-11)

A guest's television used to wear the receiver's first-generation overlay: a
black scrim with the title in the system font, a bare gradient transport with a
rounded track, a roster spine in a corner, a blinking square for "loading", red
capitals for an error, and nothing at all for a chat line, a film change, the
end of a queue or the party closing (that last one read *PLAYBACK ERROR · Error
310 · Cast it again*, with CAF's own grey app-name card bleeding through). The
web player, meanwhile, had grown codec's face. A party LOAD now puts the receiver
in that same face — `body.party` — painted from the clock poll it already makes
(`paintParty`) and from the player's own state (`pdockRender`). A solo cast is
untouched: its faces are simply hidden while the party face is up, and moving
them over later is a class removal, not a rewrite.

**What a guest TV shows, state by state.**

- **Playing:** nothing over the picture. The rule has not changed.
- **Transport activity, a seat change, a lane seating:** the **dock** — the
  app's osd-tex glass plate along the foot, the title logo (or the title in the
  HUD face), the room's clock as a pixel track with a square knob, ELAPSED ·
  who's here with a dot per link · REMAINING — up for a few seconds, then gone.
  A CAF receiver lays out at 1280×720 CSS px on any panel, so the web player's
  sizes carry over as they are; `texLaw()` keeps every art pixel a whole number
  of device pixels (a 1x art pixel is exactly 2 on the Bravia, a 2x one 3).
- **The app's OSD readouts, on the dock's right** (the request: "for a TV I would
  want those indicators"): `3840×2160 · DV` from shaka's picture size and the
  lane the set reads (never the panel's claim), FIT / ZOOM, `A:AAC 5.1 S:EN`
  (the hub says what each lane encodes — `media.audio` for the ladder,
  `tv.audio` for the DV copy — and the receiver reads its active text track),
  and the set's volume as the OSD's ten-step gauge from CAF's system volume,
  which a Bravia's own volume keys move (MUTE in red). When the lane seats or
  changes, the flash plate says it: *4K · DOLBY VISION*; the paused card keeps
  the badge plates.
- **Paused:** the dock, and after a couple of seconds the **card** — the invite
  on the television: the film's own backdrop fills the frame as the hero (the
  paused frame cut in half by a scrim read as half a screen), darkened
  on the left where the words sit and along the foot where the dock sits; the
  poster in codec's frame, the logo (sized by area like the web's, so a wide
  one-line logo doesn't dwarf a stacked one) or the title and year, the pixel
  stars, the director, the badges, the genres, the money line, and one line in
  amber: *PAUSED BY THE HOST · you'll pick up together*, or *WAITING FOR THE
  HOST TO START* at 0:00. The art comes from the room's own routes
  (`/p/<token>/art?which=poster|logo|backdrop`, keyed by title so a film change
  isn't served the last film's logo from the cache); the LOAD never carried it
  and the page's LOAD still doesn't need to. A show episode gets the show's
  hero, logo and poster.
- **Buffering, a seek:** the web's blocks loader inside the dock, in the lane
  badges' place, BUFFERING beside it.
- **A film change:** the **hold** — *Loading for everyone · <title> · starting
  together* — over a darkened frame until the room starts it for all.
- **The end of the queue:** *That's the end · waiting for the host to pick
  what's next* (or *Up next · <title>*), the same words the web player uses.
- **The room waiting on a screen:** *Waiting for <name> · their picture stopped
  · the room holds a few seconds*, with the pixel pause tinted amber.
- **The room talks:** the last two lines as a feed, lower RIGHT above the dock
  (one home on a big screen, the way a chat column sits beside a picture; the
  phone keeps its lower-left feed), the name in its colour and the words in
  Departure Mono, lit for nine seconds after a new line and faded when the room
  goes quiet. (The receiver sends `cs=` on its poll like a page, so it only
  ever receives new lines.)
- **The party closes:** a solid plate — *The party's over · thanks for
  watching* — and the player is stopped, so the dead stream can't throw the old
  error. The state poll's 404/410 or `active:false` is the signal.
- **A real error:** *Playback stopped · this TV lost the room's stream · cast it
  again from the invite*, with a small HUD-face diagnostic line underneath (the
  lane and CAF's code) that reads off a screencap.
- **Arriving and leaving:** *JOINED · NAME* / *LEFT · NAME* on the flash plate,
  and the dock up for six seconds.

**And a solo cast wears the same face** (`body.solo`, 2026-10-11 later the
same day): the app's `c` key and the phone remote get the dock with the same
readouts (A: derived from the lane — direct play passes the file's own track,
the DV / HDR10 lanes keep up to 5.1, the SDR ladder is stereo — from `ach` and
`audio` the worker now sends), the loading hold with the mark and the title
until the first frame (in place of CAF's grey card), the paused card over the
hero with the plain CODEC mark and the FILE's badge flags, the app's remote
toasts (SUBTITLES · ENGLISH, UP NEXT) on the flash plate, the held rewind
preview and a DV re-warm riding the knob, "That's the end" when the film
finishes. No roster, no feed. `codec_cast.py`'s `library_card`/`card_into`
now carry `logo`, `backdrop`, `revenueN`, `budgetN`, `ach` and `audio`. The
old solo faces (`#room`, `#info`, `#tbar`, `#ldr`, `#ctoast`, with
`paintRoom`, `paintSolo`, `tbarRender`, `ldrTick`, `ytArt`, the old
`renderBadges`) are gone — forty kilobytes of receiver — and the receiver
starts in the solo face with the hold covering CAF's grey card from first
paint; a room's LOAD switches it to the party face. `hideCafTransport`
stays: it is what keeps CAF's own seek bar off the screen.

**Pixel rules, measured on the Bravia.** The panel draws the 720p canvas at
1.5 device px per CSS px, so a text size has to be an EVEN number of CSS px
to land on whole pixels (19px is 28.5 and a pixel face smears); the badge
label wanted a one-art-pixel drop to sit centred in its readout window; the
words that are a state rather than a number — DV / HDR, FIT / ZOOM — wear the
codec face at 14px beside the HUD face's 20px, in the same dim colour, and the
app's own OSD now does the same. Judge this from 3–5× crops of a screencap,
never from the whole frame.

**Looking at it without a television.** `rx_preview.mjs` (scratchpad rig) loads
the served receiver in headless Chromium at the Bravia's canvas (1280×720, dpr
1.5) with the Cast SDK stubbed by a callable proxy and the art fetched from the
library, then paints each state from a made-up room and screenshots it — the
whole face in thirty seconds, before the real pass on the set. The real pass is
`faces_run.sh`: a hub-mode party, the TV joined through the fast road, every
state driven by `codec_party.py` and photographed over adb.

## Casting your library from someone else's house

Different problem, same plumbing: you're at a friend's place, on their wifi, and
you want something of yours on **their** TV. No party, no clock — you're in the
same room.

```bash
codec_browse.py          # mint a 12h link (codec_browse.py 4 for 4h)
codec_browse.py --off    # revoke it now
```

Open the link on your laptop or phone once you're on their wifi: your library
appears as a poster grid with search. Pick something, tap **Cast to TV**, choose
their TV. It streams from your hub over Funnel — nothing installed on their side,
nothing copied to their machine. Subtitles come along as selectable Cast tracks.

⚠ **This link is not a party invite.** A party token reaches exactly one party's
stream; this one can list and stream your *whole library*, so it's yours alone.
It expires on its own (12h default, 72h max) and `--off` kills it instantly. It
is still read-only — it cannot browse the filesystem, change anything on the hub,
or drive a party.

### From the codec app on the laptop (2026-10-12)

The laptop needs no link: it keeps its own key. Whenever it has a private road to
the hub (the LAN at home, or the tailnet), the app keeps a sliding browse token
alive in `~/.cache/codec/hub-token.json` — the same kind the phone-app link uses,
60 days idle — and the cast worker shares the file. On a wifi with neither road,
the app's HUB chip reads **FAST ROAD** (or **FUNNEL** when only the relay answers)
and the library works off the public door with that key:

- **Playing on the laptop's own screen** opens the title's own file —
  `/r/<token>/raw?i=<index>`, Range-capable — so mpv plays it at full source
  quality: HDR, Dolby Vision, the TrueHD track, exactly as on the LAN.
- **Casting to their TV** asks the hub which lane the title gets
  (`/r/<token>/hls/preflight?i=`) and loads that lane through the same door:
  the **Dolby Vision copy** lane for a clean-GOP DV title, the **HDR10** GPU lane
  for HDR, the ladder for SDR — with the title's audio tracks and subtitles
  (`/r/<token>/probe?i=`, `/r/<token>/subs?i=`), hand-rendered captions on the
  DASH lanes, chapter ticks on the remote. The fast road carries a DV copy
  (~35–80 Mbps); on the Funnel relay the receiver steps down on its own.

Every handle is a manifest **index** the hub resolves — never a path — and the
door stays read-only. YouTube on that laptop needs none of this: search, browse
and video play straight from YouTube (a livestream plays direct too, without the
hub's DVR lane).

Verified 2026-10-12 from inside the house through the real edge: the laptop and
the desktop, each sandboxed as a satellite with no private road, cast Blade Runner
(Dolby Vision) to the Bravia on the DV lane — HDR engaged on the panel, every
segment through the edge, a far seek to the one-hour mark re-warmed through it —
and the laptop's own mpv decoded the file through `/raw` at ~190 Mbps. What that
can't show is a foreign network's bandwidth: the fast road's 235 Mbps upload is
the ceiling, a DV copy wants 35–80 of it.

**When the link can't carry full quality, it steps down.** The SDR ladder always
adapted on its own; the two full-quality paths now do too:

- A roaming cast on the DV / HDR10 lane that spends 25 s buffering inside any two
  minutes after it first plays — or shows no picture 45 s after the load — re-loads
  on the adaptive ladder at the spot it reached, for the rest of that cast, with a
  toast on the TV and a notice in the app. The party receiver's own rule, applied
  from the worker's side (a solo receiver has no other lane to turn to). Verified
  on the Bravia: DV lane playing with HDR engaged → step-down → the ladder playing
  through the same edge twenty seconds later, HDR off.
- A title playing on the laptop's own screen as the raw file that sits 20 s
  waiting on mpv's cache moves to the adaptive lane at that position (the title
  keeps its resume row). The cold-start watchdog already covered a resume that
  never starts; this covers a film that starts fine and starves later. No going
  back up — the ladder's top rung is 1080p-class and it rides the real throughput.

## ⚠ The thing that will silently break this

**Tailscale node keys expire.** Every party link, every browse link and the Cast
receiver URL all hang off Funnel, and Funnel dies with the node key — quietly,
months from now, with no warning and nothing in a log. It is the same shape of
failure as an expired OAuth token.

```bash
tailscale status --json | python3 -c \
  "import json,sys;print(json.load(sys.stdin)['Self'].get('KeyExpiry'))"
```

Fix it once, in the admin console: **Machines → the hub → ⋯ → Disable key
expiry** (do the laptop too). Nothing else in this stack has a clock on it —
the Cast App ID is registered permanently, and the browse link only expires if
you ask it to.

**Renaming the machine moves every URL**, because the public name is
`<machine>.<tailnet>`. Funnel does NOT follow the rename — it keeps serving the
old name until you re-point it — and the Cast receiver URL registered with
Google has to be updated to match or casting breaks (this applies to a receiver
served from your own hub; codec's public receiver doesn't move):

```bash
sudo tailscale funnel reset && sudo tailscale funnel --bg 8299
systemctl --user restart codec-serve        # its base URL is cached per-process
# then re-register https://<new name>/cast/receiver in the Cast console
```

`sudo tailscale set --operator=$USER` once makes the funnel commands work
without root afterwards.

⚠ **Editing the Receiver URL un-publishes the Cast app.** Changing it in the
console is not enough — the app drops out of published state and the TV goes
back to `Failed to execute start app <ID>`, exactly as it did before it was
ever published. **Re-publish after editing the URL.**

Diagnose it in one step, which separates "my app is broken" from "casting is
broken":

```python
# Google's own receiver as the control. If THIS launches, casting is healthy
# and the problem is your app's registration, not the TV or the network.
tv.start_app('CC1AD845')
```

Meanwhile the sender falls back to that default receiver on its own, so a
viewer still gets the movie — they just lose TV-side sync and have to keep the
page open.

## Limits / what's next

- **Local movies only** for now (the movie-night case). A YouTube or live stream
  as the party source is a later addition.
- **Subtitles** work on both paths: the browser follower renders them itself
  (tap `CC`), and the Cast receiver gets them sideloaded as real Cast tracks, so
  the TV's own subtitle control drives them. Tracks embedded in the file *and* a
  `.srt` sitting beside it are both offered — plenty of rips carry no embedded
  track at all.
- **Your upload bandwidth is the ceiling.** Every viewer pulls their own copy, so
  three friends at 3 Mbps is 9 Mbps out of the house. Run `codec_speedtest.py`
  once; the ladder is sized against the result and divided by the guest count.
  See *4K, HDR and the ladder* above.
- **Your own TV and theirs at once** works now: put the invite on your TV (cast
  it) and join in the app — both are followers of the same hub clock, so they
  hold the same moment and either can drive.
- **~5 s residual offset on the Cast path** during playback, from HLS buffering
  on the TV. Shrinking it needs shorter segments or a different transport. A
  codec joining locally doesn't have this problem at all.
- **Cast can never work offline.** The TV resolves the App ID through *Google's*
  registry. Local playback stays offline-capable; watch parties are structurally
  online-only.
- **iPhone senders** can't drive Cast from the web (Apple). Android + Chrome, or a
  Chromecast the TV already trusts. Anyone can use `/watch` in a browser.
