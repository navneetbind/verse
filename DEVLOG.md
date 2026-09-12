# Verse — Development Log

The story of how Verse was built, the decisions made, and the gotchas hit along
the way. Verse shows **YouTube Music synced lyrics in the macOS menu bar**, with
playback controls — working in Chrome, Brave, Edge, Chromium, and Firefox.

---

## 1. The idea

Inspired by [LYRA](https://github.com/Dai-Ski/LYRA) (a macOS menu-bar synced-lyrics
app), which only reads **native** players (Spotify / Apple Music) and has no
YouTube Music or browser support.

Goal: real-time lyrics in the menu bar, sourced from **YouTube Music playing in a
browser** (the user already ran the Better Lyrics extension for on-page lyrics).

LYRA itself couldn't be reused — it's a Swift app that reads native players, not a
browser tab. So Verse is a fresh build: a **browser extension** feeding a **Swift
menu-bar app**.

---

## 2. Architecture

```
YT Music tab
 └─ content.js  (scrape track + <video>.currentTime, read Better Lyrics DOM)
     │ runtime messaging
     ▼
   background.js  (fetch lyrics / relay, own the native port)
     │ native messaging (stdin/stdout JSON frames)
     ▼
   Swift menu-bar app  (NSStatusItem + translucent NSPopover)
```

- **content.js** (isolated world): reads the current track from the player bar
  DOM, playback position from `<video>.currentTime`, and — when present — Better
  Lyrics' per-word timing from its `data-*` attributes. Does **no network** (page
  CSP would block it).
- **background.js**: owns all network. Fetches synced lyrics from LRCLIB (fallback),
  relays playback commands, and holds the native-messaging port to the app.
- **Swift app** (`menubar/`): `NativeHost.swift` reads/writes native-messaging
  frames; `main.swift` + `NowPlayingView.swift` render the menu bar + popover.

---

## 3. Key decisions

### Self-contained, not coupled to Better Lyrics' internals
Better Lyrics moved its lyric rendering into **private, versioned packages**
(`@braccato/core`, `@braccato/parsers`) — its CSS class names churn every release.
So Verse does **not** depend on scraping BL's private classes. Instead:
- Primary: read BL's **stable `data-*` attributes** (`data-time`, `data-duration`
  on `.blyrics--line` / `.blyrics--word`) — accurate real per-word timing.
- Fallback: fetch line-level lyrics from **LRCLIB** directly.

### Native messaging, not WebSocket
The first attempt used a localhost WebSocket. Dead end:
- **Firefox** force-upgrades `ws://127.0.0.1` → `wss://` on extension pages
  (CSP `upgrade-insecure-requests`); no about:config pref reliably stopped it.
- **Chrome** blocks `ws://` from a secure context as mixed content.

**Native messaging** sidesteps all of it — no port, no TLS, no CSP, no HTTPS
upgrade — and the browser **auto-launches** the app (which exits when the browser
disconnects). Bidirectional: the app writes control commands back over stdout.

### Word-level timing
LRCLIB is line-level only; no free lyrics API has true per-word timing. So:
- With Better Lyrics present → **real** per-word timing (richsync `data-*`).
- Without it → whole-line only (no fake/interpolated word highlight).

### Cross-browser from one codebase
- `manifest.json` declares **both** `background.service_worker` (Chrome) and
  `background.scripts` (Firefox) — Firefox 155 has `service_worker` disabled, so
  it needs `scripts`; Chrome ignores the extra key.
- A committed `key` gives a **stable Chrome extension ID** (so the native-host
  manifest's `allowed_origins` matches). The matching private key
  (`.chrome-key.pem`) is gitignored.

---

## 4. Features (built iteratively)

- Line-level lyrics in the menu bar.
- Better Lyrics integration → **word-by-word** highlight (real timing).
- LRCLIB fallback when BL isn't present.
- **Translucent Now Playing popover** (`NSVisualEffectView`, `.hudWindow`) — the
  Apple Now Playing look, opened from the status item.
- **Album art** (big, centered), title, artist — art fetched memory-only
  (ephemeral URLSession, no disk cache).
- **Blue seek bar**, custom-drawn (capsule + slim pill handle), drag to seek,
  smooth ~20fps handle (local time extrapolation so it glides even while the menu
  is open).
- **Transport controls** — ⏮ / ⏯ / ⏭ icon buttons (play/pause icon reflects state).
- Settings behind a **gear** button: Lyrics mode (whole line / word-by-word),
  Lyrics source (Better Lyrics / LRCLIB), Color themes (Subtle / Yellow / Green /
  Pink), Text size. All persisted in `UserDefaults`.
- **Menu-bar text**: dynamic width; music-note icon when idle; `Title — Artist`
  when paused; lyrics (active word bold) when playing.
- **Auto-close**: quits when the last YouTube Music tab closes; relaunches when
  one opens again.
- **One-command installer** (`install.sh`): builds the app, generates the Chrome
  key/ID, installs the native-host manifest for every installed browser.

---

## 5. Gotchas hit (and fixed)

| Problem | Cause | Fix |
|---|---|---|
| WebSocket never connected | FF upgrades `ws://`→`wss://` (CSP), Chrome mixed-content | Native messaging instead |
| Lyrics didn't reach the app | content-script network blocked by page CSP | Do all network in background |
| "Perfect" drifted | LRCLIB community timing ≠ YT's version timing | Prefer duration-matched result; BL richsync is authoritative |
| Album art blank | `art` field wasn't included in the `track` message | Add it to the send |
| Blue seek not showing | stock `NSSlider.trackFillColor` didn't render | Custom-drawn seek bar |
| Firefox add-on wouldn't install | FF 155 has MV3 `service_worker` disabled | Add `background.scripts` too |
| Firefox tab-close didn't quit app | url-filtered `tabs.query` behaves differently | Query all tabs, match URL manually (+ `tabs` permission) |
| Build broke after folder rename | PCH cache baked the old absolute path | `rm -rf menubar/.build`, rebuild |
| Better Lyrics only loads on click | BL is lazy — only injects DOM when the Lyrics tab is opened | Enable BL's "auto switch to lyrics tab" setting |

---

## 6. Layout

```
verse/
├─ install.sh                     one-command build + host-manifest install
├─ extension/                     MV3 (Chrome + Firefox)
│  ├─ manifest.json               (install.sh injects a stable "key")
│  ├─ content.js                  scrape track/position + Better Lyrics timing
│  └─ background.js               LRCLIB fetch, native port, tab lifecycle
├─ menubar/                       Swift SPM app
│  └─ Sources/verse/
│     ├─ main.swift               AppController: status item, popover, settings
│     ├─ NowPlayingView.swift     card: art, title, artist, seek bar, transport
│     └─ NativeHost.swift         native-messaging stdin/stdout frames
├─ README.md
└─ .chrome-key.pem                private key — gitignored, keep a backup
```

---

## 7. Notes

- **Run one browser at a time** for Verse — each spawns its own app instance (two
  menu-bar icons if both play).
- Firefox temporary add-ons unload on restart (re-load after). Chrome load-unpacked
  persists.
- Splitting lyrics across the notch (current line left, next line right) isn't
  possible — the left of the notch is reserved for the active app's menus; third
  party menu-bar items only live on the right.
- Keep `.chrome-key.pem` backed up — it reproduces the same Chrome extension ID on
  another machine.
