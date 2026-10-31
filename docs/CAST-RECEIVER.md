# codec's Cast receiver

A television shows codec's face and plays Dolby Vision because it runs
**codec's own Google Cast receiver**: a web page the TV loads when codec casts
to it. Nothing is installed on the TV. Any Chromecast, Google TV or Android TV
with Cast built in can run it.

Without it, a cast falls back to Google's plain receiver: the film still plays,
but in SDR, with Google's controls and no codec face.

## What it does

- **Plays every lane**: Dolby Vision over DASH (Cast's own DASH stack, so the
  TV's DV decoder engages), HDR10 over DASH, the adaptive SDR ladder over HLS,
  and direct play.
- **Wears codec's face**: the dock (title logo, resolution, lane, audio and
  subtitle tracks, volume, time), the loading hold, the paused card over the
  film's hero art, the end and error holds. The same pixel type as the app.
- **Draws the captions itself**, in the style the person casting chose.
- **Hands the TV's remote back to codec**: play, pause, seek, audio and
  subtitle tracks, skip intro, up next.
- **Hosts the party on a TV**: the guest web player's face, with the room's
  seats in the dock and the chat in the corner.

## The public receiver

codec ships with a public receiver, so casting works on a fresh install:

| | |
|---|---|
| App ID | `C30E2505` |
| Page | https://ciphernovaa.github.io/codec/cast/receiver/ |

The page is static and talks only to the addresses each cast hands it: your
own hub's streams and controls. It loads nothing from anyone else's machine.
Its fonts, plates and player code are all inside it.

## Hosting your own

You'd do this to change the receiver, or to keep it on infrastructure you
control.

1. **Export the page.** It's built from the same code the hub serves
   (`_party_receiver()` in `scripts/codec_serve.py`), with codec's palette and
   none of the exporting machine's settings:

       scripts/codec_receiver_export.py          # → build/cast-receiver/index.html

2. **Host it at an https address.** Cast requires https; GitHub Pages works
   (`https://<you>.github.io/<repo>/cast/receiver/`).

3. **Register an App ID** in the [Google Cast SDK Developer
   Console](https://cast.google.com/publish) (a one-time US$5 per developer
   account): Add New Application → **Custom Receiver** → your URL.
   - **Publishing needs a sender.** The console won't publish until "Sender
     Details" lists one: choose **Chrome** and give your site's address (a
     public page, never a party link: those carry a key to your library).
   - After publishing, Google's lookup finds the app within about ten minutes.
     Restart the TV's Cast service (or unplug the TV) and cast.
   - An unpublished app is meant to run on TVs registered as test devices; in
     practice a Bravia refused it until it was published.

4. **Point codec at it.** Either per machine, in `~/.config/codec/config.json`:

       "party": { "castAppId": "XXXXXXXX" }

   or for every build, in `scripts/codec_keys.py`:

       CODEC_CAST_APP = "XXXXXXXX"
       CODEC_RECEIVER_URL = "https://<you>.github.io/<repo>/cast/receiver/"

   The hub's lock lets that page's remote presses through
   (`_private_gate` → `_own_origins`).

## Working on it

The receiver is JavaScript inside a Python string in `codec_serve.py`, so every
backslash in it must be doubled. After any change, check the page the hub
serves (on the hub's public port, 8299):

    curl -s http://127.0.0.1:8299/cast/receiver \
      | python3 -c "import re,sys; print(re.findall(r'<script>(.*?)</script>', sys.stdin.read(), re.S)[-1])" > /tmp/rx.js
    node --check /tmp/rx.js

A running hub serves the receiver live, so a TV casting from it picks up a
change after `systemctl --user restart codec-serve` and a restart of the TV's
Cast service. Re-export and re-host the page to change the public one.
