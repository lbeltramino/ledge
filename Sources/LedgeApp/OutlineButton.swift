import AppKit

/// The note's headings, beside the button that opens the full editor.
///
/// Drawn rather than lettered: it sits next to the expand arrows, and a word
/// beside an icon reads as a mistake. Three rules, indented like an outline —
/// which is the picture of what opens.
///
/// Quiet until you are near it, exactly as its neighbour is. A note you are
/// only reading should carry no visible chrome at all.
final class OutlineButton: NSView {
    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    var isInert = true {
        didSet {
            setAccessibilityElement(!isInert)
            setAccessibilityRole(.button)
            setAccessibilityLabel("Headings")
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
    override func mouseDown(with event: NSEvent) { flashPress(); onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        let ink = (effectiveAppearance.isDark ? NSColor.white : NSColor.black)
            .withAlphaComponent(hovering ? 0.62 : 0.26)
        ink.setStroke()
        let inset = bounds.width * 0.24
        let box = bounds.insetBy(dx: inset, dy: inset)

        let path = NSBezierPath()
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        // Three rules, each one indented further: a heading and what sits under
        // it. The lengths differ so it reads as an outline and not as a menu.
        let rows: [(indent: CGFloat, length: CGFloat)] = [(0, 1.0), (0.28, 0.72), (0.52, 0.48)]
        for (index, row) in rows.enumerated() {
            let y = box.minY + box.height * (0.12 + CGFloat(index) * 0.38)
            path.move(to: NSPoint(x: box.minX + box.width * row.indent, y: y))
            path.line(to: NSPoint(x: box.minX + box.width * (row.indent + row.length * (1 - row.indent)), y: y))
        }
        path.stroke()
    }
}
