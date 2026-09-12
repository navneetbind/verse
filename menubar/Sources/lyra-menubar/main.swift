import AppKit

// LYRA menu-bar app: shows the current YouTube Music lyric line pushed from the
// browser extension via native messaging. Bolds the active word; keeps the
// active word visible on long lines by windowing around it.

let MAX_CHARS = 60 // cap so one very long line can't make the status item huge

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
    private var activeFont: NSFont { .systemFont(ofSize: fontSize, weight: .heavy) }
    private var sizeItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if defaults.object(forKey: "wordMode") != nil { wordMode = defaults.bool(forKey: "wordMode") }
        if defaults.object(forKey: "themeIndex") != nil { themeIndex = defaults.integer(forKey: "themeIndex") }
        if defaults.object(forKey: "fontSizeIndex") != nil { fontSizeIndex = defaults.integer(forKey: "fontSizeIndex") }
        if defaults.object(forKey: "sourceIndex") != nil { sourceIndex = defaults.integer(forKey: "sourceIndex") }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

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
              let p = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        switch p.type {
        case "line":
            lineText = (p.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if lineText.isEmpty { lineText = idle }
            activeWord = p.active ?? -1
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
        case "clear":
            lineText = idle
            activeWord = -1
        default:
            return
        }
        render()
    }

    // Build an attributed line: whole line in regular, the active word in bold.
    // If the line is longer than MAX_CHARS, window around the active word and add
    // ellipses so the sung word stays on screen.
    private func render() {
        statusItem.button?.image = nil // text modes carry no icon

        // idle (nothing playing yet) → show the music-note icon
        if !paused && (lineText.isEmpty || lineText == idle) {
            statusItem.button?.attributedTitle = NSAttributedString(string: "")
            statusItem.button?.image = noteImage
            return
        }

        // paused → show "Title — Artist"
        if paused {
            var t = songTitle
            if !songArtist.isEmpty { t += t.isEmpty ? songArtist : " — \(songArtist)" }
            if t.isEmpty { t = idle }
            statusItem.button?.attributedTitle = NSAttributedString(
                string: t, attributes: [.font: baseFont, .foregroundColor: theme.base])
            return
        }

        let words = lineText.isEmpty ? [] : lineText.components(separatedBy: " ")
        let showWord = wordMode ? activeWord : -1

        let full = NSMutableAttributedString()
        var activeRange: NSRange? = nil
        for (i, w) in words.enumerated() {
            let isActive = i == showWord
            let attrs: [NSAttributedString.Key: Any] = [
                .font: isActive ? activeFont : baseFont,
                .foregroundColor: isActive ? theme.active : theme.base,
            ]
            if isActive { activeRange = NSRange(location: full.length, length: (w as NSString).length) }
            full.append(NSAttributedString(string: w, attributes: attrs))
            if i < words.count - 1 {
                full.append(NSAttributedString(string: " ", attributes: [.font: baseFont]))
            }
        }
        if words.isEmpty {
            full.append(NSAttributedString(string: idle, attributes: [.font: baseFont]))
        }

        var display: NSAttributedString = full
        if full.length > MAX_CHARS {
            display = window(full, around: activeRange, max: MAX_CHARS)
        }

        statusItem.button?.attributedTitle = display
    }

    // Crop `s` to ~max characters, keeping `keep` (the active word) visible,
    // adding "…" on whichever side is truncated.
    private func window(_ s: NSAttributedString, around keep: NSRange?, max: Int) -> NSAttributedString {
        let len = s.length
        let center: Int
        if let k = keep { center = k.location + k.length / 2 } else { center = 0 }

        var start = center - max / 2
        if start < 0 { start = 0 }
        var end = start + max
        if end > len { end = len; start = Swift.max(0, end - max) }

        let cropped = NSMutableAttributedString(
            attributedString: s.attributedSubstring(from: NSRange(location: start, length: end - start)))
        let dots: [NSAttributedString.Key: Any] = [
            .font: baseFont, .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        if end < len { cropped.append(NSAttributedString(string: "…", attributes: dots)) }
        if start > 0 { cropped.insert(NSAttributedString(string: "…", attributes: dots), at: 0) }
        return cropped
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

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon, menu-bar only
let controller = AppController()
app.delegate = controller
app.run()
