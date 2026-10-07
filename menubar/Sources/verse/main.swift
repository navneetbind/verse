import AppKit

// Verse menu-bar app: shows the current YouTube Music lyric line pushed from the
// browser extension via native messaging. Bolds the active word; keeps the
// active word visible on long lines by windowing around it.

let SCROLL_SPEED: CGFloat = 28 // points per second when there is no word timing
let MAX_STEP: CGFloat = 5 // points per frame ceiling while catching up to the sung word
let LEAD: CGFloat = 0.35 // keep the sung word this far in from the left edge
let SCROLL_GAP: CGFloat = 60 // blank run between the end of the line and its repeat
let BAR_RESERVE: CGFloat = 24 // safety gap so the line never runs under the notch
let MAX_WIDTH: CGFloat = 560 // hard ceiling on the status item
let FALLBACK_ROOM: CGFloat = 260 // used until the menu bar reports a usable frame

struct Payload: Decodable {
    let type: String
    let text: String?
    let active: Int?
    let paused: Bool?
    let title: String?
    let artist: String?
    let art: String?
    let t: Double?
    let dur: Double?
    let src: String?
}

struct Theme {
    let name: String
    let base: NSColor
    let active: NSColor
}

final class AppController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var host: NativeHost!

    private let idle = "♪ Verse"
    private let noteImage: NSImage? = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let img = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Verse")?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = true
        return img
    }()
    private var lineText = "♪ Verse"
    private var activeWord = -1
    private var scrollTimer: Timer?
    private var pinnedWidth: CGFloat = -1
    private var lastRoom: CGFloat = FALLBACK_ROOM
    private var rightAnchor: CGFloat?
    private var paused = false
    private var songTitle = ""
    private var songArtist = ""

    // persisted settings (app relaunches each browser session)
    private let defaults = UserDefaults.standard
    private var wordMode = true // bold the active word (vs whole line only)
    private var themeIndex = 1

    private let themes: [Theme] = [
        Theme(name: "Subtle (grey / white)",
              base: .secondaryLabelColor, active: .labelColor),
        Theme(name: "Yellow (white / yellow)",
              base: .labelColor, active: .systemYellow),
        Theme(name: "Green (white / green)",
              base: .labelColor, active: .systemGreen),
        Theme(name: "Pink (white / pink)",
              base: .labelColor, active: .systemPink),
    ]
    private var theme: Theme { themes[min(themeIndex, themes.count - 1)] }

    private var lyricView: LyricView!
    private var nowPlaying: NowPlayingView!
    private var popover: NSPopover!
    private var settingsMenu: NSMenu!
    private var lyricsItems: [NSMenuItem] = []
    private var colorItems: [NSMenuItem] = []
    private var sourceItems: [NSMenuItem] = []
    private var sourceIndex = 0 // 0 = Better Lyrics (auto), 1 = LRCLIB

    private let sizes: [(String, CGFloat)] = [
        ("Small", 12), ("Medium", 13), ("Large", 14), ("Extra large", 16),
    ]
    private var fontSizeIndex = 1
    private var fontSize: CGFloat { sizes[min(fontSizeIndex, sizes.count - 1)].1 }
    private var baseFont: NSFont { .systemFont(ofSize: fontSize, weight: .regular) }
    private var activeFont: NSFont { .systemFont(ofSize: fontSize, weight: .semibold) }
    private var sizeItems: [NSMenuItem] = []

    private let widths: [(String, CGFloat)] = [
        ("Narrow", 240), ("Medium", 320), ("Wide", 400), ("Extra wide", 480),
    ]
    private var widthIndex = 1
    private var lyricWidth: CGFloat { widths[min(widthIndex, widths.count - 1)].1 }
    private var widthItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if defaults.object(forKey: "wordMode") != nil { wordMode = defaults.bool(forKey: "wordMode") }
        if defaults.object(forKey: "themeIndex") != nil { themeIndex = defaults.integer(forKey: "themeIndex") }
        if defaults.object(forKey: "fontSizeIndex") != nil { fontSizeIndex = defaults.integer(forKey: "fontSizeIndex") }
        if defaults.object(forKey: "sourceIndex") != nil { sourceIndex = defaults.integer(forKey: "sourceIndex") }
        if defaults.object(forKey: "widthIndex") != nil { widthIndex = defaults.integer(forKey: "widthIndex") }
        if defaults.object(forKey: "rightAnchor") != nil { rightAnchor = CGFloat(defaults.double(forKey: "rightAnchor")) }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        if let b = statusItem.button {
            let v = LyricView(frame: b.bounds)
            v.autoresizingMask = [.width, .height]
            b.addSubview(v)
            lyricView = v
        }

        // Now Playing card: art + title + artist + seek + transport
        nowPlaying = NowPlayingView()
        nowPlaying.onPrev = { [weak self] in self?.host.send(["cmd": "prev"]) }
        nowPlaying.onPlayPause = { [weak self] in self?.host.send(["cmd": "playpause"]) }
        nowPlaying.onNext = { [weak self] in self?.host.send(["cmd": "next"]) }
        nowPlaying.onSeek = { [weak self] t in self?.host.send(["cmd": "seek", "t": t]) }
        nowPlaying.onSettings = { [weak self] gear in self?.showSettings(from: gear) }
        nowPlaying.setPaused(paused)

        // translucent (vibrancy) popover, like the macOS Now Playing widget
        let fx = NSVisualEffectView(frame: nowPlaying.bounds)
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.autoresizingMask = [.width, .height]
        fx.addSubview(nowPlaying)
        let vc = NSViewController()
        vc.view = fx
        popover = NSPopover()
        popover.contentViewController = vc
        popover.contentSize = nowPlaying.frame.size
        popover.behavior = .transient

        // settings menu (shown from the card's gear button)
        let menu = NSMenu()
        let lyricsParent = NSMenuItem(title: "Lyrics", action: nil, keyEquivalent: "")
        let lyricsMenu = NSMenu()
        let modes = [("Whole line", 0), ("Word by word (timed)", 1)]
        for (name, tag) in modes {
            let item = NSMenuItem(title: name, action: #selector(pickLyricsMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.state = (tag == 1) == wordMode ? .on : .off
            lyricsMenu.addItem(item)
            lyricsItems.append(item)
        }
        lyricsParent.submenu = lyricsMenu
        menu.addItem(lyricsParent)

        let sourceParent = NSMenuItem(title: "Lyrics source", action: nil, keyEquivalent: "")
        let sourceMenu = NSMenu()
        for (i, name) in ["Better Lyrics (auto)", "LRCLIB"].enumerated() {
            let item = NSMenuItem(title: name, action: #selector(pickSource(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = i == sourceIndex ? .on : .off
            sourceMenu.addItem(item)
            sourceItems.append(item)
        }
        sourceParent.submenu = sourceMenu
        menu.addItem(sourceParent)

        let colorParent = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu()
        for (i, t) in themes.enumerated() {
            let item = NSMenuItem(title: t.name, action: #selector(pickColor(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = i == themeIndex ? .on : .off
            colorMenu.addItem(item)
            colorItems.append(item)
        }
        colorParent.submenu = colorMenu
        menu.addItem(colorParent)

        let sizeParent = NSMenuItem(title: "Text size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for (i, s) in sizes.enumerated() {
            let item = NSMenuItem(title: s.0, action: #selector(pickSize(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = i == fontSizeIndex ? .on : .off
            sizeMenu.addItem(item)
            sizeItems.append(item)
        }
        sizeParent.submenu = sizeMenu
        menu.addItem(sizeParent)

        let widthParent = NSMenuItem(title: "Lyric width", action: nil, keyEquivalent: "")
        let widthMenu = NSMenu()
        for (i, w) in widths.enumerated() {
            let item = NSMenuItem(title: w.0, action: #selector(pickWidth(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = i == widthIndex ? .on : .off
            widthMenu.addItem(item)
            widthItems.append(item)
        }
        widthParent.submenu = widthMenu
        menu.addItem(widthParent)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        settingsMenu = menu

        render()

        host = NativeHost()
        host.onMessage = { [weak self] str in self?.handle(str) }
        host.onEOF = { NSApp.terminate(nil) } // browser closed → exit
        host.start()
        host.send(["cmd": "source", "value": sourceIndex]) // tell extension the saved source
    }

    private func handle(_ str: String) {
        guard let data = str.data(using: .utf8),
              let p = try? JSONDecoder().decode(Payload.self, from: data) else {
            debugLog("UNDECODABLE \(str.prefix(200))")
            return
        }
        if p.type == "pos" {
            let now = Date().timeIntervalSince1970
            if now - lastPosLog > 5 {
                lastPosLog = now
                debugLog("RX pos t=\(Int(p.t ?? -1)) paused=\(p.paused.map { "\($0)" } ?? "nil")")
            }
        } else if p.type != "diag" {
            debugLog("RX \(p.type) src=\(p.src ?? "-") active=\(p.active ?? -9) \((p.text ?? p.title ?? "").prefix(60))")
        }
        switch p.type {
        case "line":
            let newText = (p.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if newText != lineText { lyricView?.offset = 0 }
            lineText = newText
            if lineText.isEmpty { lineText = idle }
            activeWord = p.active ?? -1
            lineSrc = p.src ?? "?"
        case "pos":
            paused = p.paused ?? paused
            nowPlaying.setPosition(t: p.t ?? 0, dur: p.dur ?? 0, paused: paused)
        case "paused":
            paused = p.paused ?? false
            nowPlaying.setPaused(paused)
        case "track":
            songTitle = p.title ?? ""
            songArtist = p.artist ?? ""
            nowPlaying.setTrack(title: songTitle, artist: songArtist, art: p.art ?? "")
        case "diag":
            debugLog("DIAG \(p.text ?? "")")
            return
        case "clear":
            lineText = idle
            activeWord = -1
        default:
            return
        }
        render()
    }

    // Put the lyric in the status item: static when it fits, otherwise a
    // steady right-to-left ticker so every word comes past.
    private func render() {
        statusItem.button?.image = nil // text modes carry no icon

        // idle (nothing playing yet) → show the music-note icon
        if !paused && (lineText.isEmpty || lineText == idle) {
            stopScrolling()
            lyricView.isHidden = true
            lyricView.text = NSAttributedString()
            setWidth(nil)
            statusItem.button?.image = noteImage
            return
        }

        lyricView.isHidden = false
        if let b = statusItem.button, lyricView.frame != b.bounds { lyricView.frame = b.bounds }
        let room = availableWidth()

        // paused → show "Title — Artist"
        if paused {
            var t = songTitle
            if !songArtist.isEmpty { t += t.isEmpty ? songArtist : " — \(songArtist)" }
            if t.isEmpty { t = idle }
            let title = NSAttributedString(
                string: t, attributes: [.font: baseFont, .foregroundColor: theme.base])
            stopScrolling()
            lyricView.offset = 0
            lyricView.text = title
            setWidth(room)
            return
        }

        let words = lineText.isEmpty ? [idle] : lineText.components(separatedBy: " ")
        let last = words.count - 1
        let showWord = wordMode ? min(activeWord, last) : -1

        let display = build(words, from: 0, to: last, active: showWord, uniform: false)
        // measured all-bold: the widest this line can get as the highlight moves,
        // so the item keeps one width for the whole line
        let fullWidth = build(words, from: 0, to: last, active: -1, uniform: true).size().width
        lyricView.text = display

        setWidth(room) // fixed: the item keeps one width whatever the line is
        if fullWidth <= room {
            stopScrolling()
            lyricView.target = 0
            lyricView.offset = 0
        } else if showWord > 0 {
            // slide only as far as the sung word requires, so it is never
            // carried off the edge before it has been sung
            let spaceW = NSAttributedString(
                string: " ", attributes: [.font: baseFont]).size().width
            let x = build(words, from: 0, to: showWord - 1, active: -1, uniform: true)
                .size().width + spaceW
            lyricView.loop = false
            lyricView.target = max(0, min(x - room * LEAD, fullWidth - room))
            startScrolling()
        } else if showWord == 0 {
            lyricView.loop = false
            lyricView.target = 0
            startScrolling()
        } else {
            lyricView.loop = true // no word timing — steady marquee
            startScrolling()
        }

        if debugLogURL != nil && lineText != loggedLine {
            loggedLine = lineText
            let f = statusItem.button?.window?.frame ?? .zero
            debugLog("room=\(Int(room)) anchor=\(Int(rightAnchor ?? -1)) maxX=\(Int(f.maxX)) "
                + "onScreen=\(statusItem.button?.window?.screen != nil) "
                + "px=\(Int(fullWidth)) scroll=\(scrollTimer != nil) src=\(lineSrc) | \(display.string)")
        }
    }

    // Lay out the whole line. `uniform` renders every word bold — the widest the
    // line can get — so the pinned width does not jump as the highlight moves.
    private func build(_ words: [String], from: Int, to: Int,
                       active: Int, uniform: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let hi = min(to, words.count - 1)
        guard from <= hi else { return out }
        let gap: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: theme.base]
        for i in from...hi {
            let bold = uniform || i == active
            out.append(NSAttributedString(string: words[i], attributes: [
                .font: bold ? activeFont : baseFont,
                .foregroundColor: (!uniform && i == active) ? theme.active : theme.base,
            ]))
            if i < hi { out.append(NSAttributedString(string: " ", attributes: gap)) }
        }
        return out
    }

    private func setWidth(_ w: CGFloat?) {
        guard let w, w.isFinite, w < 4000 else {
            if pinnedWidth != -1 {
                pinnedWidth = -1
                statusItem.length = NSStatusItem.variableLength
            }
            return
        }
        let want = (w + 8).rounded()
        if abs(want - pinnedWidth) > 1 {
            pinnedWidth = want
            statusItem.length = want
        }
    }

    // Diagnostics, off unless ~/.verse-debug exists.
    private let debugLogURL: URL? = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".verse-debug").path) else { return nil }
        return home.appendingPathComponent("verse-debug.log")
    }()
    private var loggedLine = ""
    private var lineSrc = ""
    private var lastPosLog: TimeInterval = 0

    private func debugLog(_ s: String) {
        guard let url = debugLogURL else { return }
        let line = "\(Date().timeIntervalSince1970) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func startScrolling() {
        guard scrollTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.scrollTick() }
        RunLoop.main.add(t, forMode: .common)
        scrollTimer = t
    }

    private func stopScrolling() {
        scrollTimer?.invalidate()
        scrollTimer = nil
        lyricView?.loop = false
    }

    private func scrollTick() {
        guard let v = lyricView else { return }
        if v.loop {
            let span = v.textWidth + SCROLL_GAP
            guard span > 0 else { return }
            var o = v.offset + SCROLL_SPEED / 30.0
            if o >= span { o -= span }
            v.offset = o
            return
        }
        let delta = v.target - v.offset
        if abs(delta) < 0.3 {
            if v.offset != v.target { v.offset = v.target }
        } else {
            v.offset += max(-MAX_STEP, min(MAX_STEP, delta * 0.12))
        }
    }

    private func availableWidth() -> CGFloat {
        guard let win = statusItem.button?.window,
              let screen = win.screen ?? NSScreen.main,
              let right = screen.auxiliaryTopRightArea else { return lastRoom }
        let notchRight = screen.frame.minX + right.minX
        let f = win.frame
        if f.width > 0 && f.maxX > notchRight && f.maxX <= screen.frame.maxX + 1 {
            if rightAnchor != f.maxX {
                rightAnchor = f.maxX
                defaults.set(Double(f.maxX), forKey: "rightAnchor")
            }
        }
        guard let anchor = rightAnchor else { return lastRoom }
        lastRoom = max(80, min(lyricWidth, anchor - notchRight - BAR_RESERVE))
        return lastRoom
    }

    @objc private func pickLyricsMode(_ sender: NSMenuItem) {
        wordMode = sender.tag == 1
        for item in lyricsItems { item.state = (item.tag == 1) == wordMode ? .on : .off }
        defaults.set(wordMode, forKey: "wordMode")
        render()
    }

    @objc private func pickColor(_ sender: NSMenuItem) {
        themeIndex = sender.tag
        for item in colorItems { item.state = item.tag == themeIndex ? .on : .off }
        defaults.set(themeIndex, forKey: "themeIndex")
        render()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showSettings(from gear: NSView) {
        settingsMenu.popUp(positioning: nil,
                           at: NSPoint(x: 0, y: gear.bounds.height + 4), in: gear)
    }

    @objc private func pickSource(_ sender: NSMenuItem) {
        sourceIndex = sender.tag
        for item in sourceItems { item.state = item.tag == sourceIndex ? .on : .off }
        defaults.set(sourceIndex, forKey: "sourceIndex")
        host.send(["cmd": "source", "value": sourceIndex])
    }

    @objc private func pickWidth(_ sender: NSMenuItem) {
        widthIndex = sender.tag
        for item in widthItems { item.state = item.tag == widthIndex ? .on : .off }
        defaults.set(widthIndex, forKey: "widthIndex")
        render()
    }

    @objc private func pickSize(_ sender: NSMenuItem) {
        fontSizeIndex = sender.tag
        for item in sizeItems { item.state = item.tag == fontSizeIndex ? .on : .off }
        defaults.set(fontSizeIndex, forKey: "fontSizeIndex")
        render()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// Settings written before Verse shipped as an app bundle live under the bare
// executable name; carry them over once so nothing resets on upgrade.
if let bundleID = Bundle.main.bundleIdentifier, bundleID != "verse",
   let old = UserDefaults(suiteName: "verse")?.persistentDomain(forName: "verse"),
   UserDefaults.standard.object(forKey: "migratedFromBareDomain") == nil {
    for (k, v) in old where UserDefaults.standard.object(forKey: k) == nil {
        UserDefaults.standard.set(v, forKey: k)
    }
    UserDefaults.standard.set(true, forKey: "migratedFromBareDomain")
}

let app = NSApplication.shared
if Setup.isUserLaunch {
    // opened by hand (or `verse --register`): set up, don't run as a lyrics host
    if CommandLine.arguments.contains("--register") {
        if Setup.isRunningFromTemporaryLocation {
            print("Verse is running from a disk image or temporary copy; move it to Applications first.")
            exit(1)
        }
        let done = Setup.register()
        _ = Setup.installExtensionFolder()
        print("Registered with: \(done.isEmpty ? "no browsers found" : done.joined(separator: ", "))")
    } else {
        Setup.runInteractive()
    }
    exit(0)
}
app.setActivationPolicy(.accessory) // no Dock icon, menu-bar only
let controller = AppController()
app.delegate = controller
app.run()
