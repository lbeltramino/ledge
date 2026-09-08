import AppKit
import LedgeCore
import LedgeIndex

/// One note's tab against the screen edge. Leans by its own `Jitter`, so the
/// stack never aligns.
///
/// Hover is *not* handled here. Per-tab tracking areas break the moment the
/// deck relays out under a stationary pointer — you end up having to leave the
/// strip and come back to select a different note. `DeckRootView` reports the
/// pointer instead, and the controller decides which tab it is over.
final class NoteTabView: NSView {

    let record: NoteRecord
    let jitter: Jitter
    var isSelected = false { didSet { needsDisplay = true } }
    /// False while the deck is at rest. An invisible tab must not sit on top of
    /// the pill quietly eating the pointer.
    var isInteractive = false
    /// Set after a rename, so the tab relabels without being rebuilt.
    var overrideTitle: String? { didSet { needsDisplay = true; updateAccessibility() } }
    /// This note has been pulled off the deck and is sitting on the desk. Its
    /// tab stays, dimmed, so nothing reshuffles and you can see where it belongs.
    var isFloating = false { didSet { needsDisplay = true; updateAccessibility() } }
    /// Set after a recolour, so the tab repaints without being rebuilt.
    var overrideColor: NoteColor? { didSet { needsDisplay = true } }
    var displayColor: NoteColor { overrideColor ?? record.color }
    /// True on a left-edge strip: the fold and the rounding swap sides.
    var mirrored = false { didSet { needsDisplay = true } }
    /// A bottom strip's tabs run across, wide and short, titles reading normally.
    var horizontal = false { didSet { needsDisplay = true } }

    var displayTitle: String { overrideTitle ?? record.displayTitle }

    var onClick: ((NoteTabView) -> Void)?
    var onContextMenu: ((NoteTabView, NSEvent) -> Void)?

    init(record: NoteRecord) {
        self.record = record
        self.jitter = Jitter(id: record.id)
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateAccessibility()
    }

    private func updateAccessibility() {
        let state = record.state == .active ? "in the deck" : "archived"
        setAccessibilityLabel("\(displayTitle), \(record.color.rawValue) note, \(state)")
        setAccessibilityHelp(isFloating
            ? "This note is on the desk. Click to bring it forward."
            : "Click to write in this note.")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func applyLean() {
        wantsLayer = true
        layer?.transform = CATransform3DMakeRotation(
            CGFloat(jitter.tabRotation) * .pi / 180, 0, 0, 1)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isInteractive ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard isInteractive else { return }
        onClick?(self)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isInteractive else { return }
        onContextMenu?(self, event)
    }

    var labelBox: NSRect {
        horizontal
            ? VerticalLabel.horizontalBox(
                for: displayTitle,
                in: NSRect(x: 0, y: 0, width: bounds.width,
                           height: bounds.height - Metrics.Tab.foldInset),
                inset: Metrics.Tab.labelInset, size: Metrics.Tab.labelSize)
            : VerticalLabel.box(
                for: displayTitle,
                in: NSRect(x: mirrored ? Metrics.Tab.foldInset : 0, y: 0,
                           width: bounds.width - Metrics.Tab.foldInset,
                           height: bounds.height),
                inset: Metrics.Tab.labelInset, size: Metrics.Tab.labelSize)
    }

    /// The natural length of a tab carrying this title: as long as the words
    /// need, between the two limits.
    static func naturalHeight(for title: String) -> CGFloat {
        let attributes = VerticalLabel.attributes(size: Metrics.Tab.labelSize, color: .black)
        let run = (title.uppercased() as NSString).size(withAttributes: attributes).width
        return min(Metrics.Tab.maxHeight,
                   max(Metrics.Tab.minHeight,
                       run + Metrics.Tab.labelInset * 2 + Metrics.Tab.labelSlack))
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = Metrics.Tab.cornerRadius
        // Rounded on the left only — the tab is flush with the screen edge.
        // Rounded on the inside only; the outer edge is flush with the screen.
        // On a bottom strip that inside edge is the top.
        let body: NSBezierPath = horizontal
            ? NSBezierPath(roundedRect: bounds.offsetBy(dx: 0, dy: radius).insetBy(dx: 0, dy: -radius),
                           xRadius: radius, yRadius: radius)
            : NSBezierPath(roundedRect: bounds.offsetBy(dx: mirrored ? -radius : radius, dy: 0)
                               .insetBy(dx: -radius, dy: 0),
                           xRadius: radius, yRadius: radius)

        // The tab is the paper, not a coloured plastic marker for it.
        let paper = Palette.paper(displayColor, dark: false, tint: jitter.paperTint)
        paper.withAlphaComponent(isFloating ? 0.34 : 1).setFill()
        body.fill()

        if isSelected {
            NSColor(white: 1, alpha: 0.30).setFill()
            body.fill()
        }

        let ink = Palette.labelInk(displayColor)

        // The perforation, as on a pad: a dashed fold between the title and the
        // screen edge.
        let fold = NSBezierPath()
        if horizontal {
            let y = bounds.maxY - Metrics.Tab.foldInset
            fold.move(to: NSPoint(x: Metrics.Tab.labelInset * 0.7, y: y))
            fold.line(to: NSPoint(x: bounds.width - Metrics.Tab.labelInset * 0.7, y: y))
        } else {
            let x = mirrored ? Metrics.Tab.foldInset : bounds.maxX - Metrics.Tab.foldInset
            fold.move(to: NSPoint(x: x, y: Metrics.Tab.labelInset * 0.7))
            fold.line(to: NSPoint(x: x, y: bounds.height - Metrics.Tab.labelInset * 0.7))
        }
        fold.lineWidth = 1
        fold.setLineDash([2.5, 3.5], count: 2, phase: 0)
        ink.withAlphaComponent(isFloating ? 0.12 : 0.30).setStroke()
        fold.stroke()

        let labelColor = ink.withAlphaComponent(isFloating ? 0.32 : 0.88)
        if horizontal {
            VerticalLabel.drawHorizontal(displayTitle,
                                         in: NSRect(x: 0, y: 0, width: bounds.width,
                                                    height: bounds.height - Metrics.Tab.foldInset),
                                         inset: Metrics.Tab.labelInset,
                                         size: Metrics.Tab.labelSize, color: labelColor)
        } else {
            VerticalLabel.draw(displayTitle,
                               in: NSRect(x: mirrored ? Metrics.Tab.foldInset : 0, y: 0,
                                          width: bounds.width - Metrics.Tab.foldInset,
                                          height: bounds.height),
                               inset: Metrics.Tab.labelInset,
                               size: Metrics.Tab.labelSize, color: labelColor)
        }
    }
}
