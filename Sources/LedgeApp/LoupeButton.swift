import AppKit

/// The way to see a drawing properly: the mark that opens it in a window of
/// its own, where it can be made bigger.
///
/// A sibling of `CodeCopyButton` and drawn in the same language — the same
/// plate, the same alphas, the same 20 pt — because they sit side by side at
/// the top right of the same block and two marks that do not match read as two
/// unrelated bits of chrome.
final class LoupeButton: NSView {

    /// The note's ink. Everything is that colour at some alpha, so the mark
    /// belongs to whatever paper it lands on.
    var ink: NSColor = .black { didSet { needsDisplay = true } }
    var onOpen: (() -> Void)?

    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    static let size: CGFloat = 20

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// Swallowed on purpose: this must not put the caret in the block.
    override func mouseDown(with event: NSEvent) { onOpen?() }
    override func mouseUp(with event: NSEvent) {}

    func forget() { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let plate = bounds.insetBy(dx: 0.5, dy: 0.5)
        ink.withAlphaComponent(hovering ? 0.10 : 0.06).setFill()
        NSBezierPath(roundedRect: plate, xRadius: 5, yRadius: 5).fill()
        ink.withAlphaComponent(hovering ? 0.16 : 0.10).setStroke()
        let edge = NSBezierPath(roundedRect: plate, xRadius: 5, yRadius: 5)
        edge.lineWidth = 1
        edge.stroke()

        let mark = markPath()
        mark.lineWidth = 1.4
        mark.lineCapStyle = .round
        ink.withAlphaComponent(hovering ? 0.72 : 0.42).setStroke()
        mark.stroke()
    }

    /// The shape alone, so a check can find it by its geometry rather than by
    /// comparing pixels that differ by alpha anyway.
    func markPath() -> NSBezierPath {
        let path = NSBezierPath()
        // a loupe: a ring, and a handle running out of it
        path.appendOval(in: NSRect(x: 4.6, y: 6.4, width: 9, height: 9))
        path.move(to: NSPoint(x: 12.6, y: 7.4))
        path.line(to: NSPoint(x: 15.8, y: 4.4))
        return path
    }
}
