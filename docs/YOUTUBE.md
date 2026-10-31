# YouTube in codec — the account, and codec's own lists

codec plays and lists YouTube through **yt-dlp** (and YouTube's own InnerTube
API, which youtube.com's page uses). There are two ways to do it, chosen in
**Settings ▸ YOUTUBE** (config `youtube.mode`):

| | **Through a browser's login** (`account`) | **codec's own lists** (`local`) |
|---|---|---|
| FOR YOU | YouTube's recommendations | YouTube's suggestions beside what you watched last, and what's new from the channels you follow — less what you've seen |
| SUBS | your subscriptions | the channels you follow in codec, from each channel's public feed |
| WATCH LATER · PLAYLISTS · HISTORY | yours on YouTube | kept by codec |
| SUBSCRIBE · ADD TO WATCH LATER · NEW PLAYLIST | change the account | change codec's lists |
| what you watch | counts on the account (history, resume on your phone) | stays in codec |
| SEARCH, channels, playing | the same either way | the same either way |

A new install starts on codec's own lists: they work at once, with nothing to
set up. A machine whose codec was already reading a browser's login stays on
it (the mode is written to config the first time the worker starts).

## Why a browser's login

Google offers a player like codec no other way in:

- **Google's official sign-in** (the YouTube Data API) covers subscriptions
  and playlists only — no recommendations, history or Watch Later, never the
  video itself — with ~100 searches a day shared by everyone using the app,
  and its rules forbid playing a video outside YouTube's own player. codec
  uses it for one thing: sending live chat (docs/CHAT.md).
- **A sign-in window inside codec** is refused by Google (embedded browsers
  can't sign in), and it would be Chromium.
- **The TV-code sign-in** ("go to youtube.com/activate") was shut off for
  tools like yt-dlp in late 2024.

So codec does what yt-dlp itself recommends: it borrows the login of a
browser that is already signed into YouTube on this machine. Nothing new to
sign up for or type in. yt-dlp's own warning applies — YouTube *can* flag an
account used by such tools; codec's own lists avoid the question entirely.

## How the login is found and read

`scripts/codec_ytaccount.py`:

- **Finding:** every profile of Zen, Firefox (incl. its XDG, Flatpak and
  Snap folders), LibreWolf, Floorp, Waterfox, Chrome, Chromium, Brave,
  Vivaldi, Edge and Opera. Whether one is signed in is read from its cookie
  database's **names** alone (`SAPISID`) — nothing is decrypted to look.
  `python3 scripts/codec_ytaccount.py` prints what it finds.
- **Naming:** a login is a yt-dlp browser spec,
  `BROWSER[+KEYRING][:PROFILE]` with PROFILE a path
  (`firefox:/home/me/.zen/abcd.Default (release)`). That one string is
  config `youtube.cookiesFromBrowser`, and what mpv's ytdl hook and the hub's
  yt-dlp are handed — every part of codec reads the same login.
- **Reading:** only YouTube's and Google's cookies are kept (the old copy held
  every site's). Firefox-family databases are read with their `-wal` file —
  a running browser keeps its newest cookies there (yt-dlp's reader skips it).
  A Chrome-family login that doesn't decrypt with yt-dlp's keyring guess is
  retried with the keyrings running on the session (KWallet, GNOME's).
- **Which channel:** a Google login can act as a channel of its own (a brand
  account). The browser then sends that channel's id with every call
  (`X-Goog-PageId`, beside `X-Goog-AuthUser`); a call without it acts as the
  plain Google account — YouTube answers "Subscription added" and the
  channel's lists never show it. `ytacct.session()` reads the id from
  YouTube's service-worker config (`/sw.js_data`, 3 KB, ~0.1 s: its data-sync
  id is `<page>||<user>`), the worker keeps it 10 minutes, and every signed
  InnerTube call carries it. yt-dlp finds the same id on its own.
- **Who:** InnerTube `account/account_menu` names the account and its picture
  (Settings shows them) — the channel's, when it acts as one. A login YouTube
  no longer accepts reads **SIGN IN AGAIN** — open youtube.com in that browser
  and it signs back in.

The worker (`scripts/codec_yt.py`) keeps a copy in
`~/.cache/codec/ytcookies.txt` (0600), refreshed every 3 minutes (YouTube
rotates its cookies) and on any sign-in error, and announces the account to
the app as an `account` event; the app hands the spec to mpv
(`MpvEngine::setYtCookieSpec`).

Each machine connects its own account. A satellite's casts are resolved on
the hub, with the hub's login.

## codec's own lists

`scripts/codec_ytlocal.py`, stored in `~/.local/share/codec/youtube.json`:

- **SUBS** reads every followed channel's public feed
  (`/feeds/videos.xml?channel_id=`, its 15 newest, ~65 ms each, 48 at once)
  and fills lengths from the channel's Videos page. 265 channels: ~2 s cold,
  instant for 15 minutes after.
- **FOR YOU** takes turns between YouTube's suggestions beside your last six
  watches (plus two older ones) and what's new from the channels you follow,
  dropping what you've watched, Shorts, and anything marked NOT INTERESTED.
- **IMPORT** (Settings ▸ YOUTUBE, when a browser is signed in) copies an
  account's subscriptions, playlists and Watch Later in. The account is only
  read; running it again adds what's new.

## The video page

`i` on a video (or hold-⏎ ▸ VIDEO PAGE, or a click on the big still) opens
its own page, laid out as youtube.com's watch page is (`qml/YouTubePage.qml`,
read by `scripts/codec_ytpage.py`):

- **left:** the picture (the resume line on it), the title, the channel —
  picture, followers, a click opens it — views, the date, likes against
  dislikes, and the plates **PLAY · SUBSCRIBE · LIKE · DISLIKE · SAVE · MORE**,
  then the full description (links and timestamps live).
- **right, the full height:** **CHAPTERS** (the creator's, else YouTube's
  automatic ones; ⏎ plays from there) · **COMMENTS** (top or newest, `f`;
  ⏎ opens a thread's replies) · **RELATED** (⏎ opens its page on top; esc
  walks back down the pages).
- The page is InnerTube `next` + `player` (the full description, the length)
  + Return YouTube Dislike (`returnyoutubedislikeapi.com`, the count YouTube
  stopped showing), all at once: ~1.3 s. Comments and more RELATED page by
  YouTube's continuation tokens.
- **Writing:** COMMENTS opens on ADD A COMMENT… (a thread: REPLY TO …,
  under the comment it answers) — a composer with your channel's picture
  and name; ⏎ posts, ⇧⏎ starts a line, esc puts it away. Hold-⏎ on a
  comment: LIKE / UNLIKE, REPLY…, REPLIES, COPY THE WORDS. (InnerTube
  `comment/create_comment` with the comments header's `createCommentParams`,
  `create_comment_reply` with a comment's `createReplyParams`,
  `perform_comment_action` with its like/unlike token.)
- LIKE / DISLIKE rate on the account (`like/like`, `like/dislike`,
  `like/removelike`); with codec's own lists, a liked video joins **Liked
  videos** at the top of PLAYLISTS. SAVE = WATCH LATER, a playlist, or a new
  one.
- Walk: the page opens on PLAY; ←/→ walk the plates and, past MORE, cross to
  the sections (and back past the first); ↑/↓ go down the column you're in.

## Channels, playlists, SUBS

- A channel or playlist opened carries a **header** (the worker's
  `listing_header`, from yt-dlp's own read): a channel's picture, handle,
  followers and banner, its tabs **VIDEOS · SHORTS · LIVE · PLAYLISTS** (←/→
  inside a channel), and **PLAY ALL · SHUFFLE · SUBSCRIBE**; a playlist's
  title, length and owner, **PLAY ALL · SHUFFLE · PIN AS A TAB**. ↑ from the
  first row walks onto the plates. PLAY ALL plays the first and queues the
  rest ahead of what was queued (a playlist whole, a channel's newest 300).
- **PIN AS A TAB** (header or hold-⏎ on a playlist row) adds the playlist as
  a tab of its own after PLAYLISTS (`~/.local/share/codec/yt-pins.json`).
- SUBS opens on **ALL CHANNELS** (every one followed, A–Z) and, with an
  account, **NOTIFICATIONS** (the account's inbox, `FEnotifications_inbox`;
  opening it marks them seen, as YouTube's bell does).
- Back returns to the row you left.
- **NOTIFICATIONS ▸ CLEAR ALL** (its header's trash, or hold-⏎) hides every
  notification on YouTube — its bell has no clear-all; "Hide this
  notification" (`notification/record_interactions`, one token a request)
  is the only removal, so codec sends it for each.

## Select mode

`v` (or ␣ on a row, or hold-⏎ ▸ SELECT SEVERAL, or a header's SELECT) starts
it: ⏎ / ␣ choose rows (✓ pressed in), hold-⏎ — or the bar's ACTIONS — acts
on what's chosen: PLAY THEM · QUEUE THEM · ADD TO WATCH LATER · ADD TO
PLAYLIST… · REMOVE FROM WATCH LATER / THIS PLAYLIST / LIKED VIDEOS / HISTORY ·
NOT INTERESTED · (channels) UNSUBSCRIBE / SUBSCRIBE · (notifications) HIDE ·
CHOOSE ALL · CLEAR. What takes something away asks first. Esc (or `v`)
ends it. The worker's `batch` op makes it one request where YouTube takes a
list (unsubscribe: `channelIds`; a playlist edit: `actions`).

## Search

The box offers **recent searches** when empty (`~/.local/share/codec/
yt-searches.json`; ⇧DEL forgets one) and **YouTube's own suggestions** as
you type (`suggestqueries-clients6.youtube.com`, ~60 ms). ↓ from the field
walks into the list — the remote can't type, so recent searches are its way
to search again.

## Needs

yt-dlp, and since late 2025 a JavaScript runtime for YouTube's checks (deno,
node or bun). Settings ▸ YOUTUBE ▸ ENGINE says what's there.

Tests: `tests/test_ytaccount.py`, `tests/test_ytlocal.py`, `tests/test_ytpage.py`
(offline).
