import AppKit

/// Keeps the tabs out.
///
/// The deck folding itself away is the whole idea, but the fan is also just nice
/// to look at — and on a wide display there is room to leave it out. This sits
/// beside the `+`, and its state belongs to the strip, not the app.
final class PinButton: NSView {
    var onClick: (() -> Void)?
    /// Dragged rather than clicked: the whole strip moves along its edge.
    var onDrag: (() -> Void)?
    private var dragOrigin: NSPoint?
    var isPinned = false {
        didSet {
            needsDisplay = true
            setAccessibilityLabel(isPinned ? "Let the tabs fold away" : "Keep the tabs out")
            setAccessibilityHelp("Click to pin the tabs out. Drag to move the whole strip along its edge.")
        }
    }
    var isInteractive = false {
        didSet {
            setAccessibilityElement(isInteractive)
            setAccessibilityRole(.button)
        }
    }

    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        shadow = DeckControlStyle.shadow()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

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
    override func mouseDown(with event: NSEvent) {
        guard isInteractive else { return }
        // Click pins; drag moves the strip. Which one it was is only known on
        // mouse-up — the same bargain the card's strip makes.
        dragOrigin = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let now = NSEvent.mouseLocation
        guard hypot(now.x - origin.x, now.y - origin.y) > 4 else { return }
        dragOrigin = nil
        onDrag?()
    }

    override func mouseUp(with event: NSEvent) {
        guard dragOrigin != nil else { return }
        dragOrigin = nil
        onClick?()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func draw(_ dirtyRect: NSRect) {
        DeckControlStyle.disc(in: bounds, hovering: hovering || isPinned)

        let ink = DeckControlStyle.ink.withAlphaComponent(isPinned ? 1 : 0.62)
        ink.setStroke()
        ink.setFill()

        // A drawing pin: a round head and a tack. Filled once it is pinned.
        let centre = NSPoint(x: bounds.midX, y: bounds.midY)
        let head = bounds.width * 0.19
        let headRect = NSRect(x: centre.x - head, y: centre.y - head * 1.5,
                              width: head * 2, height: head * 2)
        let circle = NSBezierPath(ovalIn: headRect)
        circle.lineWidth = 1.3
        isPinned ? circle.fill() : circle.stroke()

        let tack = NSBezierPath()
        tack.lineWidth = 1.3
        tack.lineCapStyle = .round
        tack.move(to: NSPoint(x: centre.x, y: headRect.maxY))
        tack.line(to: NSPoint(x: centre.x, y: centre.y + bounds.height * 0.26))
        tack.stroke()
    }
}
