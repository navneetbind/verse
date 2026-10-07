import AppKit

/// Draws the lyric line inside the status item and slides it sideways.
///
/// With word timing the view eases towards `target`, the offset that keeps the
/// sung word in view — so the text glides but never runs ahead of the vocals.
/// Without timing (LRCLIB) it falls back to `loop`: a steady marquee with a
/// second copy trailing `SCROLL_GAP` behind so the wrap has no seam.
/// Clicks fall through to the status item button underneath.
final class LyricView: NSView {
    private(set) var textWidth: CGFloat = 0

    var text: NSAttributedString = NSAttributedString() {
        didSet {
            textWidth = text.size().width
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

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard text.length > 0 else { return }
        NSBezierPath(rect: bounds).addClip() // never paint over neighbouring menu-bar items
        let h = text.size().height
        let y = ((bounds.height - h) / 2).rounded()
        // a line that fits sits centred in the fixed width; one that has to
        // slide is drawn from its scroll offset
        let fits = !loop && textWidth <= bounds.width
        let x = fits ? ((bounds.width - textWidth) / 2).rounded() : -offset
        text.draw(at: NSPoint(x: x, y: y))
        if loop {
            text.draw(at: NSPoint(x: -offset + textWidth + SCROLL_GAP, y: y))
        }
    }
}
