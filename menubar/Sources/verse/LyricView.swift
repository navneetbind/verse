import AppKit

/// Draws the lyric line inside the status item and slides it sideways.
///
/// With word timing the view eases towards `target`, the offset that keeps the
/// sung word in view — so the text glides but never runs ahead of the vocals.
/// Without timing (LRCLIB) it falls back to `loop`: a steady marquee with a
/// second copy trailing `SCROLL_GAP` behind so the wrap has no seam.
/// With `slideLines` on, a new line rises in from below while the old one
/// leaves through the top. Clicks fall through to the status item button.
final class LyricView: NSView {
    private(set) var textWidth: CGFloat = 0

    var text: NSAttributedString = NSAttributedString() {
        didSet {
            textWidth = text.size().width
            // a new line, not just the highlight moving along the same one
            if slideLines, oldValue.length > 0, text.length > 0, oldValue.string != text.string {
                outgoing = (oldValue, lastX)
                startSlide()
            }
            needsDisplay = true
        }
    }

    var offset: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    /// Where the text wants to be, in points. Only used when `loop` is false.
    var target: CGFloat = 0

    var loop = false {
        didSet { needsDisplay = true }
    }

    var slideLines = false

    private var lastX: CGFloat = 0
    private var outgoing: (text: NSAttributedString, x: CGFloat)?
    private var slideStart: CFTimeInterval = 0
    private var slideTimer: Timer?
    private let slideDuration: CFTimeInterval = 0.28

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func startSlide() {
        slideStart = CACurrentMediaTime()
        guard slideTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.needsDisplay = true
            if CACurrentMediaTime() - self.slideStart >= self.slideDuration {
                self.outgoing = nil
                self.slideTimer?.invalidate()
                self.slideTimer = nil
            }
        }
        RunLoop.main.add(t, forMode: .common)
        slideTimer = t
    }

    override func draw(_ dirtyRect: NSRect) {
        guard text.length > 0 else { return }
        NSBezierPath(rect: bounds).addClip() // never paint over neighbouring menu-bar items
        let h = text.size().height
        let y = ((bounds.height - h) / 2).rounded()
        // a line that fits sits centred in the fixed width; one that has to
        // slide is drawn from its scroll offset
        let fits = !loop && textWidth <= bounds.width
        let x = fits ? ((bounds.width - textWidth) / 2).rounded() : -offset
        lastX = x

        // 0 → 1 across the slide, eased out; 1 when no slide is running
        var p: CGFloat = 1
        if let old = outgoing {
            let raw = min(1, max(0, (CACurrentMediaTime() - slideStart) / slideDuration))
            p = CGFloat(1 - pow(1 - raw, 3))
            let ctx = NSGraphicsContext.current?.cgContext
            ctx?.saveGState()
            ctx?.setAlpha(1 - p)
            old.text.draw(at: NSPoint(x: old.x, y: y + p * bounds.height))
            ctx?.restoreGState()
        }

        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.saveGState()
        ctx?.setAlpha(p)
        let rise = (1 - p) * bounds.height
        text.draw(at: NSPoint(x: x, y: y - rise))
        if loop {
            text.draw(at: NSPoint(x: -offset + textWidth + SCROLL_GAP, y: y - rise))
        }
        ctx?.restoreGState()
    }
}
