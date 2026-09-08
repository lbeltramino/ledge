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
        PillView.render(colors: colors, in: bounds, mirrored: mirrored,
                        horizontal: horizontal, topDown: isFlipped)
    }

    /// The drawing itself, so the offscreen renderer can call it directly rather
    /// than going through a bitmap cache — which loses the smoked backing's
    /// transparency — and so the two can never drift apart.
    /// `topDown` says which way y runs in the current context: true inside the
    /// flipped view, false in an image being rendered offscreen. Without it the
    /// dashes come out in the opposite order to the notes they stand for.
    static func render(colors: [NoteColor], in bounds: NSRect,
                       mirrored: Bool = false, horizontal: Bool = false,
                       topDown: Bool = true) {
        let radius = Metrics.Pill.cornerRadius
        let body: NSBezierPath = horizontal
            ? NSBezierPath(roundedRect: bounds.offsetBy(dx: 0, dy: radius).insetBy(dx: 0, dy: -radius),
                           xRadius: radius, yRadius: radius)
            : NSBezierPath(roundedRect: bounds.offsetBy(dx: mirrored ? -radius : radius, dy: 0)
                               .insetBy(dx: -radius, dy: 0),
                           xRadius: radius, yRadius: radius)
        Palette.pillBacking.setFill()
        body.fill()

        let size = Metrics.Pill.dashSize
        guard !colors.isEmpty else {
            let dash = horizontal
                ? NSRect(x: bounds.midX - size.height / 2, y: bounds.minY + (bounds.height - size.width) / 2,
                         width: size.height, height: size.width)
                : NSRect(x: bounds.minX + (bounds.width - size.width) / 2,
                         y: bounds.midY - size.height / 2,
                         width: size.width, height: size.height)
            NSColor(white: 1, alpha: 0.35).setFill()
            NSBezierPath(roundedRect: dash, xRadius: 1.5, yRadius: 1.5).fill()
            return
        }

        var along = Metrics.Pill.verticalPadding
        for color in (topDown ? colors : colors.reversed()) {
            let dash = horizontal
                ? NSRect(x: bounds.minX + along, y: bounds.minY + (bounds.height - size.width) / 2,
                         width: size.height, height: size.width)
                : NSRect(x: bounds.minX + (bounds.width - size.width) / 2, y: bounds.minY + along,
                         width: size.width, height: size.height)
            Palette.tab(color).setFill()
            NSBezierPath(roundedRect: dash, xRadius: 1.5, yRadius: 1.5).fill()
            along += size.height + Metrics.Pill.dashGap
        }
    }
}
