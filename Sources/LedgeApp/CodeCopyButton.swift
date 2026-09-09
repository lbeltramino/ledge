import AppKit

/// The one-step way to get a snippet back out of a note.
///
/// When the note *is* the code, what you want is not to select it — it is to
/// have it. So the block offers itself: hover, and a small mark appears at the
/// top right of it; click, and the block is on the clipboard without its
/// fences, ready to paste into a terminal.
///
/// Drawn rather than assembled from a symbol and a bezel: it sits on paper, and
/// a system button on paper looks like a system button on paper.
final class CodeCopyButton: NSView {
    /// The note's ink. Everything here is that colour at some alpha, so the
    /// mark belongs to whatever paper it lands on.
    var ink: NSColor = .black { didSet { needsDisplay = true } }
    var onCopy: (() -> Void)?

    private var hovering = false { didSet { needsDisplay = true } }
    private(set) var showingConfirmation = false { didSet { needsDisplay = true } }
    private var reset: Timer?
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

    override func mouseDown(with event: NSEvent) {
        // Swallowed on purpose: this must not put the caret in the block.
        onCopy?()
        confirm()
    }

    override func mouseUp(with event: NSEvent) {}

    /// The tick, for as long as it takes to notice and no longer.
    func confirm() {
        showingConfirmation = true
        reset?.invalidate()
        reset = Timer.scheduledTimer(withTimeInterval: 1.1, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.showingConfirmation = false }
        }
    }

    func forget() {
        reset?.invalidate()
        showingConfirmation = false
        hovering = false
    }

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
        mark.lineJoinStyle = .round
        ink.withAlphaComponent(showingConfirmation ? 0.75 : (hovering ? 0.72 : 0.42)).setStroke()
        mark.stroke()
    }

    /// The shape alone, without the colour it is drawn in.
    ///
    /// Separated so a check can compare the two states by their geometry: the
    /// alpha differs between them anyway, so comparing pixels proves only that
    /// something changed, not that the tick was ever drawn.
    func markPath(confirmed: Bool? = nil) -> NSBezierPath {
        let path = NSBezierPath()
        if confirmed ?? showingConfirmation {
            // a tick
            path.move(to: NSPoint(x: 5.5, y: 10.2))
            path.line(to: NSPoint(x: 8.6, y: 6.8))
            path.line(to: NSPoint(x: 14.5, y: 13.2))
        } else {
            // two sheets, one behind the other
            let front = NSRect(x: 4.5, y: 4.5, width: 8.5, height: 8.5)
            path.appendRoundedRect(front, xRadius: 2, yRadius: 2)
            path.move(to: NSPoint(x: 7.2, y: 13.6))
            path.line(to: NSPoint(x: 14.2, y: 13.6))
            path.appendArc(withCenter: NSPoint(x: 14.2, y: 12.1), radius: 1.5,
                           startAngle: 90, endAngle: 0, clockwise: true)
            path.line(to: NSPoint(x: 15.7, y: 7.4))
        }
        return path
    }
}
