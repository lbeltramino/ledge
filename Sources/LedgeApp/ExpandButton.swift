import AppKit

/// Opens the note in the full editor. Quiet until you are near it.
final class ExpandButton: NSView {
    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    var isInert = true {
        didSet {
            setAccessibilityElement(!isInert)
            setAccessibilityRole(.button)
            setAccessibilityLabel("Open in editor")
        }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isInert ? nil : super.hitTest(point)
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
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        let ink = (effectiveAppearance.isDark ? NSColor.white : NSColor.black)
            .withAlphaComponent(hovering ? 0.62 : 0.26)
        ink.setStroke()
        let inset = bounds.width * 0.22
        let box = bounds.insetBy(dx: inset, dy: inset)
        let arm = box.width * 0.42

        let path = NSBezierPath()
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        // top-left corner
        path.move(to: NSPoint(x: box.minX, y: box.minY + arm))
        path.line(to: NSPoint(x: box.minX, y: box.minY))
        path.line(to: NSPoint(x: box.minX + arm, y: box.minY))
        // bottom-right corner
        path.move(to: NSPoint(x: box.maxX, y: box.maxY - arm))
        path.line(to: NSPoint(x: box.maxX, y: box.maxY))
        path.line(to: NSPoint(x: box.maxX - arm, y: box.maxY))
        // the diagonal between them
        path.move(to: NSPoint(x: box.minX + arm * 0.5, y: box.minY + arm * 0.5))
        path.line(to: NSPoint(x: box.maxX - arm * 0.5, y: box.maxY - arm * 0.5))
        path.stroke()
    }
}
