# Everything codec does

The README is the tour. This is the full inventory, area by area, of what four
months and sixty-six releases built. Where a feature has its own page, it's
linked.

**Contents:**
[Home & the look](#home--the-look) ·
[The library](#the-library) ·
[Info pages](#info-pages) ·
[Playback](#playback) ·
[Subtitles](#subtitles) ·
[HDR & Dolby Vision](#hdr--dolby-vision) ·
[Casting](#casting) ·
[The TV remote & the couch](#the-tv-remote--the-couch) ·
[Watch party](#watch-party) ·
[YouTube](#youtube) ·
[The queue](#the-queue) ·
[Settings](#settings) ·
[Hub & satellites](#hub--satellites) ·
[The importer](#the-importer) ·
[Desktop integration](#desktop-integration) ·
[Built to be measured](#built-to-be-measured)

---

## Home & the look

**A weapon-wheel instrument, not a feed.** Home is the film's own fanart
full-bleed, its clearlogo, its badges and one meta line, and below them a wheel
of sections (MOVIES · TV SHOWS · YOUTUBE · STATS · SETTINGS) with a readout card
that counts what's inside each.

- **CONTINUE**, a deck seated on the key legend, sized from the real tray on every screen
- **The synopsis decodes**, line by line under redaction bars (`RedactText`, reusable anywhere)
- **The home globe**: a Qt Quick 3D Earth from NASA imagery, front face and dual-sun lighting
- **Attract mode**: when the room goes idle, a codec-face clock with equal digit cells and the date, the spotlight's badges, its synopsis decoding and scrolling, each title held until it reads through, new arrivals first
- **Mech-UI**: every plate a 9-slice of pixel art; a fixed steel palette; the integer-scale law (art only scales in whole steps); `Cascade` fans every list in like Settings' rows
- **The MGS1 Codec and HUD fonts**, extended from the game's glyphs to full Latin-1, Latin Extended-A, ligatures and symbols, so nearly every word, keycap and transport glyph wears them ([fonts](fonts/README.md))
- **Optical alignment, measured**: MGS text sits on its ink's real baseline; every media badge, in the app and on the web, has its window one art pixel inside the frame on all sides and its label's ink centred, then one screen pixel lower
- **UI sounds**: five cues (move · bump · select · back · open), one per event-loop turn with the strongest winning, from a sound pack (the MGS pack, or six synthesised ones), through one native PipeWire stream that pauses while silent; quiet while a film plays locally
- **The garage editor** (experimental): an Armored Core-style live rig with vim-style modes, per-element targeting, a crosshair, and about 200 dials for every plate, glow, ink and offset; the look it tunes bakes into `assets/look/look.json`
  - three presets (`1`–`3`, `shift` to save), A/B compare, undo/redo, randomize all or one group, an ASSET BAY that plays sprite strips, "open in Aseprite" with hot reload; STATS has a garage of its own with about 60 more dials
- **A CRT is a first-class screen**: its visible glass measured on the tube (17/20/12/6 px hidden of 1280×1024), every view filled to it, its own legend and scale
- **RESUME HERE**: when another codec in the house is playing, the top strip says so (`ON <ROOM> · TITLE · 1:23:45 · PRESS E`); press `e` and the film moves to this screen at that moment, and the other one stops
- **Tune the room's mood**: spotlight interval, synopsis reveal (redact · light · type · off), attract-mode delay, glass translucency, and a PYWAL theme that takes its accent from your wallpaper
- **`ctrl+r`** picks something at random

## The library

- **Films and shows from your own folders**, picked on first launch in **CHOOSE MEDIA PATHS** (codec's own folder browser; MOVIES or TV per path, suggested from what's inside)
- **Art without a key of your own**, or with yours: TMDB posters, backdrops and details; fanart.tv and TMDB clearlogos
- **Badges read from the file**, never its name: 4K / 1080p, DOLBY VISION, HDR10, ATMOS, 5.1, the cut
- **NEW**: anything the importer placed in the last 14 days that nobody has started, from the importer's own ledger (file times lie: remuxes rewrite old files)
- **Resume** everywhere, a watch database with play counts, and the remembered audio/subtitle choice per film
- **SKIP INTRO and UP NEXT** from offline detectors that find every show's intro and every film's credits
- **Bonus features**: every extra a film or show carries, grouped, with frame thumbnails
- **Viewing guides**: a fan's map of a long show re-cuts the episode list (*The X-Files*: EVERY EPISODE ↔ MYTH + TOP, the films under THE MOVIE headings where they belong); autoplay, UP NEXT and the remote's resume follow the cut
- **Double episodes** read as one ("S09E19-20 · The Truth"); every episode remembers its own air year
- **The grid**: every film, the selected one large, filters, sorts, search
- **STATS**: a cockpit of its own: watch-time rankings, a terrain graph of the last 30 days, a tach-style THIS WEEK gauge, the most-watched title's poster as its hero
- **The library watches the disks** and updates itself; a delete reconciles everywhere
- **Bulk actions**: select titles with `␣`, then mark them watched or unwatched, or queue them, in one go; MARK WATCHED UP TO HERE on an episode; mark a whole show
- **Filters that combine**: format (only the ones your library has), HAS EXTRAS and genre at once, e.g. Dolby Vision + Action; sort by title, rating or year
- **AUDIT LIBRARY**: probes every file and checks its resolution, HDR, Dolby Vision and audio against what the library claims
- **Update modes**: LIVE (a title appears the moment it lands), ON LAUNCH, or OFF; a quick RESCAN that fetches no art
- **DELETE FILE** from the context menu, with a confirm; tidies away a junk-only release folder and updates every device
- **Import from Kodi**: metadata, art and watched/resume state seeded from Kodi's database (`kodi_import.py`)
- **A duplicate finder** that compares copies on every axis that matters, decode checks and stream hashes included, and lets you choose (`codec_dupes.py`)

## Info pages

- **The full dossier** (`i`): poster in codec's frame, clearlogo title art, drawn badges, the cast and crew, revenue and budget, MORE LIKE THIS
- **Spec rows**: VIDEO · AUDIO · SUBS with the real codec names (HEVC, AV1, VC-1, TrueHD, DD+, DTS, PGS, VobSub…), plus WRITTEN BY, STUDIO, COUNTRY, LANGUAGE, and REMUX and WATCHED ×N badges
- **Keys on the page**: `t` trailer, `a` queue, `c` cast, `w` watched, `b` bonus features
- **PLAY** on the page (⏎ twice to watch), and a half info view on home that grows into the full page
- **Shows** get a page with a navigation spine, the next episode, and a separate episode list with its guide
- **A short page grows** its MORE LIKE THIS posters into the room it has
- **Back and forward** walk a history of pages

## Playback

libmpv inside the app, never a child player.

- **HDR passthrough** on an HDR display (PQ end to end), engaged per film
- **The OSD wears the film's clearlogo** with its year, or S01E03 · "Name"; play/pause in a fixed column; chapters marked on the scrub bar
- **Adaptive zoom** follows the film's aspect ratio: IMAX sequences fill the screen, scope films letterbox
- **200 % volume** like VLC, with a detent at 100
- **Steady frames under FreeSync**: an idle app presents every refresh so a VA panel doesn't flicker below its range; FRAME RATE (match the display, or 60)
- **The miniplayer**: free placement, calm snapping, codec's own pixel transport
- **The cursor hides**, even over HDR films where the compositor rebuilds the window
- **Night mode**: dialogue up, booms down; a sleep timer (30 · 60 min)
- **Autoplay** the next episode, with a countdown
- **"CONTINUE WATCHING?"** after three episodes in a row, instead of another countdown
- **One volume everywhere**: `9` / `0` / `m` drive the system volume, and the keyboard's volume keys show on codec's OSD instead of the desktop's popup; past 100 it becomes the player's own boost
- **SOUND OUTPUT** picker, AUDIO LANGUAGE preference (a per-film pick still wins), SEEK STEP (5 · 10 · 15 · 30 s, the remote follows it), HDR PEAK BRIGHTNESS (from the panel's EDID, or forced)
- **Frame grab**: `ctrl+s` saves the current frame to `~/Pictures/codec`
- **The details**: speed `[` `]` (reset `⌫`), frame step `,` `.`, chapters PgUp / PgDn, `End` to a livestream's live edge, subtitles lift while the OSD shows, `z` cycles fit · zoom · stretch
- **The sleep timer** ends with a cancellable 3-2-1 and darkens the displays

## Subtitles

- **Fetched** from several providers (keyless by default, OpenSubtitles with a key), and **judged**: the right film by title, the right episode out of a season pack, the film's own runtime, clean text; featurettes get nothing
- **Re-timed against the film's own audio** (ffsubsync), on a queue on the hub; the raw file is kept. One film's subtitles had been 9.7 s late
- **Fetched mid-cast**, with no restart; press again to REFETCH the next-best release
- **Image subtitles** (PGS) turned into styled text by OCR, per track, at idle disk priority
- **One caption face everywhere**: the app, the TV's receiver overlay, burned-in lanes, YouTube; CAPTION SIZE, FONT, COLOUR and BACKGROUND, separately for this screen and the TV
- **The X / C nudge** shows on screen and is remembered per film
- **SUB FILE STYLING**: CODEC'S draws every subtitle in one look; ITS OWN keeps a styled `.ass` file's fonts and colours
- **A nightly sweep** fetches for every title with none, and OCRs image subtitles ahead of time so the TV's subtitle menu opens instantly

## HDR & Dolby Vision

- **Four cast lanes**, picked film by film from the file itself: **Dolby Vision** (the film's profile 8.1 stream copied into DASH, not re-encoded), **HDR10 / HEVC** (10-bit NVENC transcode, PQ kept), an **SDR ladder** (adaptive, tone-mapped on the GPU with libplacebo, zero-copy Vulkan → CUDA), and **direct play**
- **Every Dolby Vision title casts at full bitrate**: 24 of 24, plus 139 of 139 non-DV titles, verified by eye and by the receiver's own dropped-frame stats on a Sony Bravia
- **Resolution-robust HDR**: the HDR path never scales or pads; 1080p and odd heights cast as HDR at their own size
- **The manifest is sized to the film**: a long DV cast no longer buffers more towards the end
- **Seeks** land smoothly in all three lanes; far DV seeks re-warm by design (open GOPs) behind a deliberate buffer
- **The DV toolkit**: profile 7 dual-layer discs converted to profile 8.1 losslessly; irregular-GOP DV re-encoded to a clean-GOP copy (NVENC base + the original RPU + lossless audio), verified or discarded, originals never touched; a TUI and CLI (`codec_dv`)
- **Untagged 10-bit SDR** encodes cast in the right colours

## Casting

The full walk-through: [CASTING.md](CASTING.md).

- **codec's own Google Cast receiver**, public and static: nothing to install on the TV ([CAST-RECEIVER.md](CAST-RECEIVER.md))
- **One face for every cast**: the dock (logo, resolution, lane, audio and subtitle tracks, fit/zoom, the TV's volume, time), the loading hold, the first-play mark, the paused card over the film's hero art, end and error holds
- **The output picker** (`c`): this machine, every Cast device found, ADD DEVICE by scan or address
- **Instant zoom and fit** on the TV; fast backward seeks on HDR10 and SDR
- **Captions drawn by the receiver** in the caster's style, live as you change it
- **Casting from the laptop**, upstairs or away: close the lid and keep control
- **SEND TO HUB**: move what a satellite is playing onto the hub's TV
- **DEFAULT TV**: the TV you last cast to, or the first one found
- **Playback speed on the TV** (0.75×–2×) and a CC key that toggles English subtitles

## The TV remote & the couch

- **The television's own remote drives codec** while casting: play, pause, seek, audio and subtitle tracks, skip intro, up next, the screen mode
- **A programmable remote** over Bluetooth: its keys mapped in Settings ▸ REMOTE, with a key map drawn in the readout
- **INPUT** moves codec between screens (the main display ⇄ a CRT), **POWER** sleeps the other one
- **The mouse as a remote**: the wheel walks, a tilt changes tabs, a click selects
- **`h` and `l` only ever move**, on every screen, so the keys never surprise you
- **A held key** ticks evenly, about eight steps a second
- **A phone remote**: a web page served by the hub that searches the library, picks a device, plays or queues, seeks, pauses and sets the volume
- **Lend the library** by QR code or a time-limited link, revoked instantly (`codec_browse.py`)
- **Fourteen programmable keys** on a Bluetooth remote: screen mode, subtitles, audio, cast, output, the other screen, watch party, sleep, trailer, resume, add to queue
- **Every keycap hint is a button**: click one and codec presses that key
- **The queue from the remote**: CH+ / CH− move an item, STOP removes it, hold STOP to clear

## Watch party

- **One invite link**: guests land in codec's web player, in codec's face, on the host's frame; the link unfurls into the film's poster and logo with a live badge ([PARTY.md](PARTY.md))
- **Seats**: present, seated, joining, with ping dots; LOCK ROOM; drop a guest; ask to rejoin
- **Everyone waits for the slowest**: a film change holds every screen on "Loading for everyone", then starts them together
- **Guests' TVs in 4K HDR and Dolby Vision** over a fast road; the Funnel relay for everything else; guests at home offered PLAY DIRECT · LAN
- **Each guest climbs only as high as their device decodes**: the browser's own decoding report per rung, a frames-shown watcher, a step down on decoder errors
- **Chat** in Departure Mono, on the web player and the TV; reactions
- **The party face on a TV**: the guest player's dock with the app's readouts, the room's seats, chat lower right
- **A 60-day phone-app link** for a regular guest
- **Vote to rewind**: `r` asks the room to go back 30 seconds, and the hub rewinds when enough of the room agrees
- **ROOM SYNC**: a mixing-desk gauge of the delay the room is holding, each screen's position and the recent worst, with lag tracked per guest
- **Six reactions**: 😂 😮 🔥 ❤️ 👏 👀
- **Keys**: `c` copies the invite, `t` opens chat, `l` locks the room, `x` ends it for everyone; leaving keeps the film playing on your screen
- **An upload speed test** sizes the guests' quality ladder from your real upload (`codec_speedtest.py`)

## YouTube

Two ways in ([YOUTUBE.md](YOUTUBE.md)):

- **Through a browser's login**: every Firefox- and Chrome-family profile found and named; recommendations, subscriptions, Watch Later, playlists, history; signed calls act as the right channel
- **codec's own lists**, no account: follows read from public feeds, Watch Later, playlists, history, liked videos, a FOR YOU of its own; import from an account or a Google Takeout

And either way:

- **Every video's own page** (`i`): channel, followers, views, date, likes against Return YouTube Dislike, the full description with live links and timestamps; CHAPTERS · COMMENTS (top or newest, threads, liked, written) · RELATED
- **Channels and playlists** get a header: picture, banner, VIDEOS · SHORTS · LIVE · PLAYLISTS, PLAY ALL · SHUFFLE · SUBSCRIBE · PIN AS A TAB
- **SUBS**: ALL CHANNELS A–Z and NOTIFICATIONS, with CLEAR ALL
- **Select mode** (`v`): queue, save, remove, hide or unsubscribe many at once, one request where YouTube takes a list
- **Search** with recents (the remote's way to search again) and YouTube's own suggestions
- **Livestreams** with a 4-hour rewind, LIVE FOR and watched readouts, and live chat on screen
- **Fast**: a concurrent worker with a cache and prefetch; pages by continuation
- **Cast** any video, captions included
- **DOWNLOAD TO LIBRARY**: an offline copy of any video, made by the hub
- **Search filters**: sort (relevance · date · views · rating), uploaded (hour · today · week…), type, length, LIVE NOW ONLY
- **The video menu**: NOT INTERESTED, REMOVE FROM HISTORY, GO TO CHANNEL, CAST TO…, SEND TO HUB QUEUE, COPY LINK
- **Live chat**: @-mention autocomplete from recent chatters, and sending (with a one-time API setup, [CHAT.md](CHAT.md))

## The queue

- **One line-up for every format**: Dolby Vision films, HDR10 films, 1080p episodes and YouTube videos side by side, each played in its own best format
- **Saved queues**: save a line-up by name, load it later
- **Shuffle, repeat, move, remove**; episode autoplay feeds the same queue
- **The queue follows you** between devices
- **It survives a restart**, and `t` hands the whole queue to the hub for another screen to play

## Settings

- **Eight sections on hexagon tabs**: PLAYBACK · SUBTITLES · DISPLAY · CAST · LIBRARY · YOUTUBE · REMOTE · SYSTEM
- **Values on purpose**: ←/→ walk sections, ⏎ grabs a value, ←/→ step it live, ⏎ applies, esc cancels
- **A readout panel**: caption samples for this screen and the TV, the dock corner, the remote's key map, the selected row's help
- **Fits every screen**, with every input (wheel, tilt, trackball, keys)

## Hub & satellites

- **SHARE THIS LIBRARY** writes the background service and announces the hub on the network
- **USE A CODEC HUB** finds hubs and asks to join; the hub shows "<NAME> WANTS TO JOIN · ⏎ ALLOW"
- **The hub's lock**: paired devices only (or a network you mark trusted); a foreign web page gets media only; a DNS-rebinding Host is refused; keys stored hashed, files 0600
- **A satellite browses offline** from its manifest and art cache
- **Away from home**: one link model (LAN, tailnet, fast road, relay, away) probed in the background; a 60-day browse key; the title's own file at full quality, Dolby Vision included, or a cast on the lane the hub picks, stepping down when the link can't feed it
- **HUB NAME**, and a HUB chip in the top strip

## The importer

- **Tells a show from a film** (season markers, SxxEyy files, TMDB) and files series under their show
- **Imports the moment a download finishes**, and tells codec to rescan
- **Faststart**: files remuxed so direct play starts instantly
- **Arrivals ledger**: the real arrival time behind NEW

## Desktop integration

- **MPRIS**: media keys, the desktop's player widget, seek and volume
- **Single instance**: a second launch hands over to the running one
- **D-Bus**: move to a screen, come to the front, rescan
- **Suspend inhibited** while casting, so a closed laptop keeps control
- **The pointer** handed over hidden when codec moves screens
- **Open with codec**: files and URLs (YouTube links included) from the file manager or the command line; `--enqueue` adds them to a running codec's queue; `--display` and `--mode crt|hd` skip the screen chooser
- **The remote's INPUT and POWER keys** work system-wide, even with codec closed

## Built to be measured

- **An ops panel** for the hub's long jobs and its drives on one screen (`codec_dash.py`); `codec_pause.sh` pauses every heavy job and later puts them back exactly where they were
- **A smoke test** that plays a few seconds down every cast lane and decodes what came out (`codec_smoke.py`)
- **An offscreen screenshot harness** for every view at every screen size (`tools/shots/`), sandboxed from the real session
- **A frame meter** (`CODEC_FPS=1`): fps, render time, CPU, stalls; an idle screen reads 0–2 fps
- **A headless preview of the Cast receiver** in every state, at the TV's own canvas
- **Python tests** for the workers and the hub's logic
- **Audits**: a 146-finding pass and a 104-finding pass, fixed and verified
