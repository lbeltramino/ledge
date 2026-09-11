import AppKit

/// The way back from an unlocked table.
///
/// The padlock that unlocks one is drawn on the table, so unlocking takes the
/// button away with the drawing — a door that only opens. This is the same mark
/// in its open state, laid over the raw text, and pressing it draws the table
/// again.
final class TableLockMark: NSView {
    var onLock: (() -> Void)?
    var ink: NSColor = .black { didSet { needsDisplay = true } }
    var paper: NSColor = .white { didSet { needsDisplay = true } }

    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    static let size: CGFloat = 20

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: TableLockMark.size, height: TableLockMark.size))
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

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
    override func mouseDown(with event: NSEvent) { onLock?() }
    override func mouseUp(with event: NSEvent) {}

    override func draw(_ dirtyRect: NSRect) {
        (paper.blended(withFraction: hovering ? 0.20 : 0.12, of: ink) ?? paper).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()

        let colour = ink.withAlphaComponent(hovering ? 0.78 : 0.48)
        colour.setStroke()
        let body = NSRect(x: bounds.minX + bounds.width * 0.28, y: bounds.minY + bounds.height * 0.46,
                          width: bounds.width * 0.44, height: bounds.height * 0.34)
        // The shackle swung open — the difference between this and the closed
        // one on a drawn table, and the whole message.
        let shackle = NSBezierPath()
        shackle.lineWidth = 1.3
        shackle.appendArc(withCenter: NSPoint(x: body.midX + body.width * 0.42, y: body.minY),
                          radius: body.width * 0.34, startAngle: 20, endAngle: 200)
        shackle.stroke()
        colour.setFill()
        NSBezierPath(roundedRect: body, xRadius: 1.5, yRadius: 1.5).fill()
    }
}
