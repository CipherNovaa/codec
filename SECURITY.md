# Security

codec's hub serves your media library over your network, and parts of it over
the internet for watch parties and roaming. This page is how that's kept safe,
and how to report a problem.

## Reporting

Please **don't open a public issue** for a security problem. Use GitHub's
private reporting instead: the **Security** tab → **Report a vulnerability**.
Include what you found, how to reproduce it, and what it exposes.

## The model

**Two doors.** The hub (`scripts/codec_serve.py`) listens on two ports:

| Port | Who reaches it | What it answers |
|---|---|---|
| **8200**, private | The machine itself; devices on your network that you've paired | The library, the cast lanes, controls, pairing |
| **8299**, public | Anyone with a link, when you expose it (Tailscale Funnel or your own name) | Only token-scoped, read-only party and roaming routes |

**The private door is locked** (`_private_gate`):

- loopback is always allowed; a network you mark **TRUSTED** is allowed
- a paired device presents its key (a header, a cookie or a query parameter);
  keys are stored only as SHA-256 hashes, in files readable only by you (0600)
- a TV is allowed while it's being cast to
- a request carrying a **foreign web origin** gets media files only, never
  controls or writes
- a **Host** header that isn't one of the hub's own names is refused (against
  DNS rebinding)

**The public door is narrow:**

- every route is scoped by a token (a party's, or a satellite's browse key)
- media is addressed by **integer library index**, never by a filesystem path;
  nothing on the public port can name a file
- `POST` is refused there; writes and controls stay on the private port
- a party token reaches that party's stream and nothing else; a party expires
  after six idle hours
- tokens are redacted from the hub's logs

**Rules for anyone changing the hub:** a new public route must take only an
integer index the hub resolves itself, never a path, and must never be added to
the private port's open list by accident.

## Out of scope

- The YouTube side reads a browser's cookies **for YouTube and Google only**,
  on the same machine, at the user's choice. It never sends them anywhere but
  YouTube.
- codec does not encrypt your library at rest; protect the disks as you would
  anyway.
