import AppKit

/// The corner you pull to make a note bigger.
///
/// It sits on the corner furthest from the screen edge — the only one a card
/// pinned to an edge actually has free — and appears with the rest of the
/// controls, once you have clicked into the note.
final class ResizeHandle: NSView {

    /// Reports the drag as a delta in screen points.
    var onResize: ((CGSize) -> Void)?
    var onFinished: (() -> Void)?

    var isInert = true {
        didSet {
            setAccessibilityElement(!isInert)
            setAccessibilityRole(.button)
            setAccessibilityLabel("Resize note")
        }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isInert ? nil : super.hitTest(point)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isInert else { return }
        var last = NSEvent.mouseLocation
        while let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                         until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { break }
            let now = NSEvent.mouseLocation
            onResize?(CGSize(width: now.x - last.x, height: now.y - last.y))
            last = now
        }
        onFinished?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let ink = (effectiveAppearance.isDark ? NSColor.white : NSColor.black)
            .withAlphaComponent(0.30)
        ink.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.3
        path.lineCapStyle = .round
        // three short diagonals, the shortest at the outside
        for (index, inset) in [CGFloat(3), 7, 11].enumerated() {
            let length = bounds.width - inset - 3
            guard length > 0 else { continue }
            _ = index
            path.move(to: NSPoint(x: inset, y: bounds.height - 3))
            path.line(to: NSPoint(x: 3, y: bounds.height - inset))
        }
        path.stroke()
    }
}
