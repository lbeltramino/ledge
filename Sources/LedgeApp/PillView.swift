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
    /// Something is being dragged over the edge and would land here.
    var isDropTarget = false { didSet { needsDisplay = true } }
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
    /// At rest the deck is a stripe with a dash per note, and past a handful
    /// that stops being information: nobody counts twenty dashes, and two
    /// hundred would draw a stripe the length of the display. It says "a few
    /// notes" and stops.
    static let mostDashes = 7

    static func shown(_ count: Int) -> Int { min(max(count, 1), mostDashes) }

    static func length(for count: Int) -> CGFloat { height(for: count) }

    static func height(for count: Int) -> CGFloat {
        let n = shown(count)
        return CGFloat(n) * Metrics.Pill.dashSize.height
            + CGFloat(n - 1) * Metrics.Pill.dashGap
            + Metrics.Pill.verticalPadding * 2
    }

    override func draw(_ dirtyRect: NSRect) {
        PillView.render(colors: colors, in: bounds, mirrored: mirrored,
                        horizontal: horizontal, topDown: isFlipped)
        guard isDropTarget else { return }
        // A wash over the stripe while something is held above it. The deck
        // fans out at the same moment, so this only has to say "here", not
        // explain itself.
        let radius = Metrics.Pill.cornerRadius
        let glow = horizontal
            ? NSBezierPath(roundedRect: bounds.offsetBy(dx: 0, dy: radius).insetBy(dx: 0, dy: -radius),
                           xRadius: radius, yRadius: radius)
            : NSBezierPath(roundedRect: bounds.offsetBy(dx: mirrored ? -radius : radius, dy: 0)
                               .insetBy(dx: -radius, dy: 0),
                           xRadius: radius, yRadius: radius)
        NSColor(white: 1, alpha: 0.45).setFill()
        glow.fill()
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

        // Only as many as the stripe shows. The first few, in order, so the
        // colours you see at rest are the colours at the top of the deck.
        let shown = Array(colors.prefix(PillView.mostDashes))
        var along = Metrics.Pill.verticalPadding
        for color in (topDown ? shown : shown.reversed()) {
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
