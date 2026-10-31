# Live chat: watching vs. sending

**Watching** a YouTube live chat in codec works with zero setup — press `c` in
the player on any live stream. Messages, emoji (standard + custom), badges and
superchats all render. That half rides yt-dlp's live-chat follower and the
browser cookies codec already uses.

**Sending** a message is different. YouTube gates the private
`send_message` endpoint behind a BotGuard/PoToken browser challenge that an
external app can't solve — every reverse-engineered send returns
`400 INVALID_ARGUMENT` (while the same account's Watch-Later and playlist
writes succeed, so it's send-specific, not an auth problem). The **only**
reliable, non-fragile way to send is the official **YouTube Data API v3**
(`liveChatMessages.insert`) with OAuth — the same path Nightbot, StreamElements
and OBS chat plugins use.

That needs a one-time, ~5-minute setup.

## One-time setup

1. **Google Cloud project** → <https://console.cloud.google.com/> → create a
   project (any name).
2. **Enable the API**: APIs & Services → Library → search "YouTube Data API v3"
   → **Enable**.
3. **OAuth consent screen**: APIs & Services → OAuth consent screen →
   User type **External** → fill the required app name + your email.
   - Add the scope `https://www.googleapis.com/auth/youtube.force-ssl`.
   - **Publish the app** ("In production"). You'll get an "unverified app"
     warning at sign-in that you click through once — that's fine for personal
     use. (If you leave it in *Testing* mode instead, Google expires the login
     every 7 days, so publish it.)
4. **Credentials**: APIs & Services → Credentials → Create credentials →
   **OAuth client ID** → Application type **Desktop app** → Create. Copy the
   **client ID** and **client secret**.
5. **Tell codec** — add to `~/.config/codec/config.json`:
   ```json
   {
     "youtube": {
       "oauthClientId": "…apps.googleusercontent.com",
       "oauthClientSecret": "…"
     }
   }
   ```
   (Keep any existing `youtube` keys like `cookiesFromBrowser`.)
6. **Authorize once**:
   ```
   codec_yt.py --auth
   ```
   It opens your browser to Google's consent screen; approve, and codec stores
   a refresh token in `~/.config/codec/youtube-oauth.json` (chmod 600). From
   then on, sending Just Works — press `c`, then `⏎`, type, `⏎`.

## Quota

`liveChatMessages.insert` costs 50 units; the default daily quota is 10,000, so
~200 sent messages/day — plenty for personal use. Reading chat costs nothing
(it doesn't go through the Data API).

## Notes

- The refresh token is long-lived once the app is **published**; in *Testing*
  mode it expires weekly (Google's rule) — just re-run `--auth` if that bites.
- "this video has no active live chat" = the stream isn't live (or chat is
  off). "youtube api quota reached" = you hit the daily cap.
- Reading YouTube's own cross-device resume position back *into* codec isn't
  possible — YouTube doesn't expose it to non-browser clients — so history sync
  is one-way (codec → your YouTube history).
