import AppKit

// Custom-drawn blue seek bar with click/drag to seek. Extrapolates position
// locally so it moves smoothly even while the menu is open.
final class SeekBar: NSView {
    var onSeek: ((Double) -> Void)?

    private let elapsed = NSTextField(labelWithString: "0:00")
    private let total = NSTextField(labelWithString: "0:00")
    private let inset: CGFloat = 10

    private var lastT = 0.0
    private var dur = 0.0
    private var paused = true
    private var stamp = Date()
    private var dragging = false
    private var dragFrac = 0.0

    override init(frame: NSRect) {
        super.init(frame: frame)
        for l in [elapsed, total] {
            l.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            l.textColor = .secondaryLabelColor
            addSubview(l)
        }
        elapsed.frame = NSRect(x: 0, y: 0, width: 44, height: 14)
        elapsed.alignment = .left
        total.frame = NSRect(x: frame.width - 44, y: 0, width: 44, height: 14)
        total.alignment = .right

        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common) // ~20fps -> smooth handle glide
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(t: Double, dur d: Double, paused p: Bool) {
        lastT = t; dur = d; paused = p; stamp = Date()
        if !dragging { needsDisplay = true; refreshLabels(current: t) }
    }
    private func tick() {
        guard !dragging else { return }
        needsDisplay = true
        refreshLabels(current: currentTime())
    }
    private func currentTime() -> Double {
        let cur = paused ? lastT : lastT + Date().timeIntervalSince(stamp)
        return min(max(cur, 0), dur > 0 ? dur : cur)
    }
    private func frac() -> Double {
        if dragging { return dragFrac }
        return dur > 0 ? currentTime() / dur : 0
    }
    private func refreshLabels(current cur: Double) {
        elapsed.stringValue = fmt(dragging ? dragFrac * dur : cur)
        total.stringValue = fmt(dur)
    }

    override func draw(_ rect: NSRect) {
        let w = bounds.width - inset * 2
        let h: CGFloat = 6
        let y = bounds.height / 2 + 2
        // capsule track
        let track = NSRect(x: inset, y: y, width: w, height: h)
        NSColor.white.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: track, xRadius: h / 2, yRadius: h / 2).fill()

        // blue fill capsule
        let f = CGFloat(min(max(frac(), 0), 1))
        let fw = max(w * f, h) // keep a round cap even near zero
        let fill = NSRect(x: inset, y: y, width: fw, height: h)
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: fill, xRadius: h / 2, yRadius: h / 2).fill()

        // slim pill handle (Apple Now Playing style — no circle)
        let hw: CGFloat = 4, hh: CGFloat = 14
        let hx = inset + w * f - hw / 2
        let handle = NSRect(x: hx, y: y + h / 2 - hh / 2, width: hw, height: hh)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: handle, xRadius: hw / 2, yRadius: hw / 2).fill()
    }

    private func fracAt(_ event: NSEvent) -> Double {
        let p = convert(event.locationInWindow, from: nil)
        let w = bounds.width - inset * 2
        return min(max((p.x - inset) / w, 0), 1)
    }
    override func mouseDown(with event: NSEvent) {
        dragging = true; dragFrac = fracAt(event); needsDisplay = true
        refreshLabels(current: 0)
    }
    override func mouseDragged(with event: NSEvent) {
        dragFrac = fracAt(event); needsDisplay = true; refreshLabels(current: 0)
    }
    override func mouseUp(with event: NSEvent) {
        dragFrac = fracAt(event)
        let t = dragFrac * dur
        lastT = t; stamp = Date(); dragging = false
        needsDisplay = true; refreshLabels(current: t)
        onSeek?(t)
    }

    private func fmt(_ sec: Double) -> String {
        guard sec.isFinite, sec >= 0 else { return "0:00" }
        let s = Int(sec.rounded(.down))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

// The Now Playing card: big centered art, title, artist, seek bar, transport.
final class NowPlayingView: NSView {
    private let art = NSImageView()
    private let title = NSTextField(labelWithString: "Verse")
    private let artist = NSTextField(labelWithString: "")
    private let seek = SeekBar(frame: NSRect(x: 10, y: 65, width: 260, height: 40))
    private var playpause: NSButton!
    private var lastArtURL = ""
    private let session = URLSession(configuration: .ephemeral) // memory-only

    private var gear: NSButton!

    var onPrev: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onNext: (() -> Void)?
    var onSettings: ((NSView) -> Void)?
    var onSeek: ((Double) -> Void)? {
        get { seek.onSeek } set { seek.onSeek = newValue }
    }

    private let W: CGFloat = 280
    private let H: CGFloat = 305

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 305))
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        art.frame = NSRect(x: (W - 120) / 2, y: H - 16 - 120, width: 120, height: 120)
        art.wantsLayer = true
        art.layer?.cornerRadius = 10
        art.layer?.masksToBounds = true
        art.imageScaling = .scaleProportionallyUpOrDown
        addSubview(art)

        title.frame = NSRect(x: 10, y: H - 146 - 22, width: W - 20, height: 22)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.alignment = .center
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)

        artist.frame = NSRect(x: 10, y: H - 170 - 16, width: W - 20, height: 16)
        artist.font = .systemFont(ofSize: 12)
        artist.textColor = .secondaryLabelColor
        artist.alignment = .center
        artist.lineBreakMode = .byTruncatingTail
        addSubview(artist)

        addSubview(seek)

        let prev = button("backward.fill", size: 16, x: 63, #selector(tapPrev))
        playpause = button("play.fill", size: 22, x: 121, #selector(tapPlayPause))
        let next = button("forward.fill", size: 16, x: 179, #selector(tapNext))
        _ = prev; _ = next

        gear = NSButton()
        gear.isBordered = false
        gear.bezelStyle = .regularSquare
        gear.imagePosition = .imageOnly
        gear.image = symbol("ellipsis.circle", size: 15)
        gear.contentTintColor = .secondaryLabelColor
        gear.target = self
        gear.action = #selector(tapGear)
        gear.frame = NSRect(x: W - 30, y: H - 30, width: 22, height: 22)
        addSubview(gear)
    }

    private func symbol(_ name: String, size: CGFloat) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = true
        return img
    }
    private func button(_ sym: String, size: CGFloat, x: CGFloat, _ action: Selector) -> NSButton {
        let b = NSButton()
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.imagePosition = .imageOnly
        b.image = symbol(sym, size: size)
        b.contentTintColor = .labelColor
        b.target = self
        b.action = action
        b.frame = NSRect(x: x, y: 16, width: 38, height: 38)
        addSubview(b)
        return b
    }

    func setTrack(title t: String, artist a: String, art url: String) {
        title.stringValue = t.isEmpty ? "Verse" : t
        artist.stringValue = a
        guard !url.isEmpty, url != lastArtURL, url.hasPrefix("https://"),
              let u = URL(string: url) else { return }
        lastArtURL = url
        session.dataTask(with: u) { [weak self] data, _, _ in
            guard let data, let img = NSImage(data: data) else { return }
            DispatchQueue.main.async { self?.art.image = img }
        }.resume()
    }
    func setPosition(t: Double, dur: Double, paused: Bool) {
        seek.update(t: t, dur: dur, paused: paused)
        setPaused(paused)
    }
    func setPaused(_ paused: Bool) {
        playpause?.image = symbol(paused ? "play.fill" : "pause.fill", size: 22)
    }

    @objc private func tapPrev() { onPrev?() }
    @objc private func tapPlayPause() { onPlayPause?() }
    @objc private func tapNext() { onNext?() }
    @objc private func tapGear() { onSettings?(gear) }
}
