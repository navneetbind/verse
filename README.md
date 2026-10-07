# Verse for YT Music

Synced **YouTube Music** lyrics in the **macOS menu bar**, word by word, from
**Firefox, Chrome, Brave, Edge, Vivaldi or Arc**.

A browser extension reads the current song and lyrics from YouTube Music and
sends the line being sung to a small menu-bar app over native messaging.

## Install

### Homebrew

```bash
brew install --cask navneetbind/tap/verse
```

### DMG

Download `Verse-<version>.dmg` from
[Releases](https://github.com/navneetbind/verse/releases), drag **Verse** into
**Applications**, then open it once. It connects itself to your browsers and
shows the last step.

Verse is not notarized, so the first open needs **System Settings → Privacy &
Security → Open Anyway**.

### Then add the extension

The extension is copied to `~/Library/Application Support/Verse/extension`.

- **Chrome, Brave, Edge, Vivaldi, Arc**: open the extensions page, turn on
  **Developer mode**, click **Load unpacked**, choose that folder. It stays
  installed across restarts.
- **Firefox**: `about:debugging#/runtime/this-firefox` → **Load Temporary
  Add-on…** → choose `manifest.json` in that folder. Firefox drops it on restart
  (a permanent install needs Mozilla signing).

Play a song on <https://music.youtube.com>. The browser starts Verse by itself;
lyrics appear in the menu bar.

## Features

- **Word-by-word highlight** when the lyrics have real word timing; plain lines
  otherwise.
- **Fixed width** you choose (gear → Lyric width). Short lines sit centred; long
  lines glide so the word being sung stays in view.
- **Now Playing card** on click: artwork, seek bar, previous / play-pause / next.
- Colours, text size, and lyrics source (Better Lyrics or LRCLIB) in the gear
  menu.
- Appears only while a YouTube Music tab is open.

## Lyrics sources

1. **[Better Lyrics](https://github.com/better-lyrics/better-lyrics)**, if you
   have it installed: Verse reads its lyrics from the page, including real
   per-word timing. Verse opens the Lyrics tab for a moment on each new song so
   Better Lyrics loads, then puts you back where you were.
2. **[LRCLIB](https://lrclib.net)** otherwise: line-level lyrics, no word
   highlight.

## How it works

```
YouTube Music tab
  pageclock.js   (page world)  song position + transport via the player API
  content.js     (extension)   song, Better Lyrics parsing, current line/word
        │ runtime messaging
  background.js                LRCLIB fallback, relays to the app
        │ native messaging (stdin/stdout frames)
  Verse.app                    menu-bar item, Now Playing card
```

The song position comes from YouTube Music's player API rather than the
`<video>` element, whose time runs on across tracks on some layouts.

Native messaging rather than a local WebSocket: Firefox upgrades `ws://127.0.0.1`
to `wss://` on extension pages and Chrome blocks it as mixed content. Native
messaging needs no port or TLS, and the browser launches the app itself.

## Build from source

Needs the Xcode command line tools.

```bash
./build.sh            # build/Verse.app (universal)
./build.sh install    # copy to ~/Applications and connect to your browsers
./build.sh dmg        # build/Verse-<version>.dmg
```

`install.sh` is the older developer setup: it runs the app straight from
`menubar/.build` and generates the Chrome extension key.

## Files

```
verse/
├─ build.sh              app bundle, install, DMG
├─ install.sh            developer setup (runs from .build)
├─ extension/            MV3, Chrome + Firefox
│  ├─ manifest.json
│  ├─ content.js
│  ├─ pageclock.js
│  └─ background.js
└─ menubar/              Swift package
   ├─ Resources/         Info.plist, icon
   ├─ scripts/make_icon.swift
   └─ Sources/verse/     main, LyricView, NowPlayingView, NativeHost, Setup
```
