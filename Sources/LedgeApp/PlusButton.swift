import AppKit

/// The one affordance the deck shows: a new note, below the last tab.
final class PlusButton: NSView {
    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        shadow = DeckControlStyle.shadow()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var isInteractive = false {
        didSet {
            setAccessibilityElement(isInteractive)
            setAccessibilityRole(.button)
            setAccessibilityLabel("New note")
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isInteractive ? super.hitTest(point) : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { guard isInteractive else { return }; flashPress(); onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        DeckControlStyle.disc(in: bounds, hovering: hovering)

        let ink = DeckControlStyle.ink
        ink.setStroke()
        let arm: CGFloat = bounds.width * 0.24
        let path = NSBezierPath()
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: bounds.midX - arm, y: bounds.midY))
        path.line(to: NSPoint(x: bounds.midX + arm, y: bounds.midY))
        path.move(to: NSPoint(x: bounds.midX, y: bounds.midY - arm))
        path.line(to: NSPoint(x: bounds.midX, y: bounds.midY + arm))
        path.stroke()
    }
}
