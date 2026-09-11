import AppKit
import LedgeCore

/// The headings of a note, as a list you can jump from.
///
/// Drawn on the note's own paper rather than in a system popover: a panel with
/// a shadow and a title bar over a sticky note would be the first thing in the
/// app that looks like it came from somewhere else.
final class OutlineBar: NSView {
    var onPick: ((Headings.Item) -> Void)?
    var onClose: (() -> Void)?

    private var items: [Headings.Item] = []
    private var rows: [NSRect] = []
    private var hovered: Int?
    private var tracking: NSTrackingArea?

    private var paper: NSColor = .white
    private var ink: NSColor = .black

    override var isFlipped: Bool { true }

    private var rowHeight: CGFloat { max(18, Metrics.Card.titleSize * 1.5) }
    private var font: NSFont { .systemFont(ofSize: max(9, Metrics.Card.titleSize * 0.82)) }

    /// As tall as its list, up to a point: past that it is a wall of text, and
    /// the note underneath has disappeared.
    func height(for count: Int) -> CGFloat {
        min(CGFloat(min(count, 9)) * rowHeight + 10, 260)
    }

    func show(_ found: [Headings.Item], paper: NSColor, ink: NSColor) {
        items = found
        self.paper = paper
        self.ink = ink
        hovered = nil
        isHidden = found.isEmpty
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved,
                                            .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let found = rows.firstIndex { $0.contains(point) }
        if found != hovered { hovered = found; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) { hovered = nil; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rows.firstIndex(where: { $0.contains(point) }), index < items.count else {
            onClose?()
            return
        }
        onPick?(items[index])
    }

    /// Truncates to fit. Not `VerticalLabel.fitted`, which upper-cases as it
    /// goes — that is for the lettering on a tab, and a heading is a sentence.
    static func fitted(_ text: String, available: CGFloat,
                       attributes: [NSAttributedString.Key: Any]) -> NSString {
        let full = text as NSString
        guard full.size(withAttributes: attributes).width > available else { return full }
        var trimmed = text
        while !trimmed.isEmpty,
              ((trimmed + "…") as NSString).size(withAttributes: attributes).width > available {
            trimmed.removeLast()
        }
        return (trimmed + "…") as NSString
    }

    override func draw(_ dirtyRect: NSRect) {
        // The paper again, a shade deeper — the same move the card's own band
        // makes, so this reads as a fold of the note rather than a window.
        let plate = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: 6, yRadius: 6)
        (paper.blended(withFraction: 0.10, of: ink) ?? paper).setFill()
        plate.fill()
        ink.withAlphaComponent(0.10).setStroke()
        plate.lineWidth = 1
        plate.stroke()

        rows = []
        var y: CGFloat = 5
        for (index, item) in items.prefix(9).enumerated() {
            let row = NSRect(x: 1, y: y, width: bounds.width - 2, height: rowHeight)
            rows.append(row)

            if hovered == index {
                ink.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: row.insetBy(dx: 3, dy: 1), xRadius: 4, yRadius: 4).fill()
            }

            // Depth by indent, the way an outline reads, and the deeper ones
            // lighter so the shape of the note is visible at a glance.
            let indent = CGFloat(item.level - 1) * 11
            let weight: NSFont.Weight = item.level == 1 ? .semibold : .regular
            let alpha = max(0.45, 1 - CGFloat(item.level - 1) * 0.16)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: font.pointSize, weight: weight),
                .foregroundColor: ink.withAlphaComponent(alpha),
            ]
            let available = bounds.width - 20 - indent
            let fitted = OutlineBar.fitted(item.text, available: available, attributes: attributes)
            fitted.draw(at: NSPoint(x: 10 + indent,
                                    y: y + (rowHeight - font.pointSize * 1.3) / 2),
                        withAttributes: attributes)
            y += rowHeight
        }

        if items.count > 9 {
            let more = "+\(items.count - 9)" as NSString
            more.draw(at: NSPoint(x: 10, y: bounds.height - 15),
                      withAttributes: [.font: NSFont.systemFont(ofSize: font.pointSize * 0.85),
                                       .foregroundColor: ink.withAlphaComponent(0.40)])
        }
    }
}
