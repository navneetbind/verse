# LYRA for YT Music

Real-time synced lyrics for **YouTube Music** shown in the **macOS menu bar** —
word-by-word, in **Chrome / Brave / Edge / Chromium / Firefox**.

A browser extension scrapes the current track + playback position from YouTube
Music, fetches synced lyrics from [LRCLIB](https://lrclib.net), and pushes the
current line (with the active word) to a tiny Swift menu-bar app over **native
messaging**.

```
YT Music tab ──content.js (scrape title/artist + <video>.currentTime)
                  │ runtime messaging
                  ▼
             background.js (LRCLIB fetch + LRC parse + line/word pick)
                  │ native messaging (stdin frames — no port/TLS/CSP)
                  ▼
             menubar app (Swift, NSStatusItem) ── bolds the active word
```

Self-contained — does **not** depend on the Better Lyrics extension (its lyric DOM
lives in a private, versioned package that would break on every release). Better
Lyrics can keep running on-page alongside this.

## Install (one command)

```bash
~/Downloads/lyra-ytm/install.sh
```

It builds the app, gives the extension a stable Chrome ID, and installs the
native-messaging host manifest for every browser you have. Then load the
extension:

- **Chrome / Brave / Edge** (persists across restarts):
  `chrome://extensions` → enable **Developer mode** → **Load unpacked** →
  select `extension/`.
- **Firefox** (temporary — reload after each restart):
  `about:debugging#/runtime/this-firefox` → **Load Temporary Add-on** →
  select `extension/manifest.json`.

Play a song on <https://music.youtube.com>. The browser auto-launches the
menu-bar app; lyrics appear in the bar. **Re-run `install.sh` after any change to
the Swift app** (rebuilds + refreshes the host path).

> Firefox permanent install needs AMO signing (a Mozilla account). Chrome
> load-unpacked is persistent with no signing, so it's the recommended daily home.

## Features
- **Line + word-level sync.** LRCLIB provides line timing; words are interpolated
  across each line's duration and the active word is **bolded**. (No free lyrics
  source has true per-word timestamps — this is an approximation, not official
  richsync.)
- **Long lines** window around the active word (with `…`) so the sung word stays
  visible instead of being truncated.
- **Pause** shows a `⏸` prefix.
- **Dropdown menu** shows the current `Title — Artist`, plus Quit.

## How it works
- **content.js** (isolated world): polls `ytmusic-player-bar .title` / `.byline`
  for the track and listens to the `<video>` `timeupdate` for position. No network
  (page CSP would block it). Forwards to the background service worker.
- **background.js** (MV3 service worker, Chrome + Firefox 121+): fetches
  `syncedLyrics` from LRCLIB (`/api/get` exact, `/api/search` fallback), parses
  `[mm:ss.xx]`, and sends `{type:"line", text, active}` on each line/word change
  over the native-messaging port.
- **menubar app**: `NativeHost.swift` reads Firefox/Chrome native-messaging frames
  (4-byte LE length + JSON) from stdin; `main.swift` renders the line as an
  attributed `NSStatusItem` title, bolding the active word.

## Why native messaging (not WebSocket)
Firefox force-upgrades `ws://127.0.0.1` → `wss://` on extension pages
(CSP `upgrade-insecure-requests`); Chrome blocks `ws://` as mixed content. A
plain-`ws` local server is a dead end. Native messaging has no port, no TLS, no
CSP, no HTTPS upgrade — and the browser auto-launches the app (it exits when the
browser disconnects).

## Files
```
lyra-ytm/
├─ install.sh          build + install host manifests + Chrome key/id
├─ extension/          MV3 (Chrome + Firefox)
│  ├─ manifest.json    (install.sh injects a "key" for a stable Chrome id)
│  ├─ content.js
│  └─ background.js
├─ menubar/            Swift SPM app
│  └─ Sources/lyra-menubar/{main.swift, NativeHost.swift}
└─ .chrome-key.pem     generated private key (keep; do not commit)
```

## Limits
- Word timing is interpolated, not true per-word.
- Menu bar windows long lines (~55 chars visible).
- Some tracks have no synced lyrics (falls back to the song title).
