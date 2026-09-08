import AppKit
import LedgeCore

/// The deck at rest: twelve points of pill against the screen edge, one
/// coloured dash per note. No window, no Dock icon, nothing visibly running.
final class PillView: NSView {

    var colors: [NoteColor] = [] {
        didSet {
            needsDisplay = true
            setAccessibilityLabel(colors.count == 1 ? "Ledge, 1 note" : "Ledge, \(colors.count) notes")
        }
    }
    var onClick: (() -> Void)?
    /// True on a left-edge strip: the rounding is on the other side.
    var mirrored = false { didSet { needsDisplay = true } }
    var horizontal = false { didSet { needsDisplay = true } }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityHelp("Your notes. Reach over to fan them out.")
    }

    override var isFlipped: Bool { true }

    /// The pill's long dimension: down the screen on a side strip, across it on
    /// a bottom one.
    static func length(for count: Int) -> CGFloat { height(for: count) }

    static func height(for count: Int) -> CGFloat {
        let n = max(count, 1)
        return CGFloat(n) * Metrics.Pill.dashSize.height
            + CGFloat(n - 1) * Metrics.Pill.dashGap
            + Metrics.Pill.verticalPadding * 2
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = Metrics.Pill.cornerRadius
        // Rounded on the left only; the right edge is flush with the screen.
        let body: NSBezierPath = horizontal
            ? NSBezierPath(roundedRect: bounds.offsetBy(dx: 0, dy: radius).insetBy(dx: 0, dy: -radius),
                           xRadius: radius, yRadius: radius)
            : NSBezierPath(roundedRect: bounds.offsetBy(dx: mirrored ? -radius : radius, dy: 0)
                               .insetBy(dx: -radius, dy: 0),
                           xRadius: radius, yRadius: radius)
        Palette.pillBacking.setFill()
        body.fill()

        guard !colors.isEmpty else {
            let d = Metrics.Pill.dashSize
            let dash = horizontal
                ? NSRect(x: bounds.midX - d.height / 2, y: (bounds.height - d.width) / 2,
                         width: d.height, height: d.width)
                : NSRect(x: (bounds.width - d.width) / 2, y: bounds.midY - d.height / 2,
                         width: d.width, height: d.height)
            NSColor(white: 1, alpha: 0.35).setFill()
            NSBezierPath(roundedRect: dash, xRadius: 1.5, yRadius: 1.5).fill()
            return
        }

        let size = Metrics.Pill.dashSize
        var along = Metrics.Pill.verticalPadding
        for color in colors {
            let dash = horizontal
                ? NSRect(x: along, y: (bounds.height - size.width) / 2,
                         width: size.height, height: size.width)
                : NSRect(x: (bounds.width - size.width) / 2, y: along,
                         width: size.width, height: size.height)
            Palette.tab(color).setFill()
            NSBezierPath(roundedRect: dash, xRadius: 1.5, yRadius: 1.5).fill()
            along += size.height + Metrics.Pill.dashGap
        }
    }
}
