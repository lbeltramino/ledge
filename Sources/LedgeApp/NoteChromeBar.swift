import AppKit
import LedgeCore

/// The row along the bottom of a note: its colour, and the three things you can
/// do to it. Every one of these was previously only reachable by knowing a
/// shortcut, which is not reachable at all.
final class NoteChromeBar: NSView {

    var color: NoteColor { didSet { needsDisplay = true } }
    var onColor: ((NoteColor) -> Void)?
    var onDelete: (() -> Void)?
    var onArchive: (() -> Void)?
    var onClose: (() -> Void)?

    private let deleteButton = ChromeButton(title: "Delete", destructive: true)
    private let archiveButton = ChromeButton(title: "Archive")
    private let closeButton = ChromeButton(title: "Close")

    private var swatchRects: [(NoteColor, NSRect)] = []
    private var hoveredSwatch: NoteColor?
    private var tracking: NSTrackingArea?

    /// While invisible the bar is not there at all: a click where a button
    /// would be simply lands on the paper and focuses the note.
    var isInert = true

    static var height: CGFloat { max(26, Metrics.Card.titleSize * 2.1) }
    private var swatchSize: CGFloat { max(8, Metrics.Card.titleSize * 0.95 * fitScale) }
    private var swatchGap: CGFloat { max(4, Metrics.Card.titleSize * 0.5 * fitScale) }

    /// On a screen too small to give the card its natural width, the controls
    /// give way rather than overlapping. There is always *some* width at which
    /// they must, so the row shrinks to fit and drops the swatches last.
    private var fitScale: CGFloat {
        guard bounds.width > 0 else { return 1 }
        let natural = naturalWidth
        guard natural > bounds.width else { return 1 }
        return max(0.72, bounds.width / natural)
    }

    /// Measured, not guessed: the swatches stay only while they and the buttons
    /// both actually fit. A ratio was close enough to look right and still let
    /// them collide.
    private var showsSwatches: Bool {
        guard bounds.width > 0 else { return true }
        return swatchRowWidth + buttonRowWidth <= bounds.width
    }

    private var swatchRowWidth: CGFloat {
        CGFloat(NoteColor.allCases.count) * (swatchSize + swatchGap)
    }

    private var buttonRowWidth: CGFloat {
        [deleteButton, archiveButton, closeButton]
            .reduce(CGFloat(0)) { $0 + $1.intrinsicContentSize.width + 4 }
    }

    /// What the row wants, before any squeezing.
    private var naturalWidth: CGFloat {
        let swatch = max(10, Metrics.Card.titleSize * 0.95)
        let gap = max(5, Metrics.Card.titleSize * 0.5)
        let swatches = CGFloat(NoteColor.allCases.count) * (swatch + gap)
        // Measured at scale 1 on purpose: `fitScale` is derived from this, and
        // deriving it from the already-scaled buttons makes the two chase each
        // other and the row twitch on every layout.
        let buttons = [deleteButton, archiveButton, closeButton]
            .reduce(CGFloat(0)) { $0 + $1.unscaledWidth + 4 }
        return ceil(swatches + buttons + 6)
    }

    /// The narrowest this row can be drawn without its controls colliding.
    /// The card refuses to be narrower than this, which is why Delete no longer
    /// lands on top of the colour swatches.
    var minimumWidth: CGFloat { naturalWidth }

    init(color: NoteColor) {
        self.color = color
        super.init(frame: .zero)
        deleteButton.onClick = { [weak self] in self?.onDelete?() }
        archiveButton.onClick = { [weak self] in self?.onArchive?() }
        closeButton.onClick = { [weak self] in self?.onClose?() }
        for button in [deleteButton, archiveButton, closeButton] { addSubview(button) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isInert ? nil : super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    /// Every control's position, for checking that nothing moves when it should
    /// not.
    var controlFrames: [NSRect] {
        [deleteButton.frame, archiveButton.frame, closeButton.frame] + swatchRects.map { $0.1 }
    }

    /// True when any two controls have been squeezed into each other — the one
    /// thing this row must never do.
    var hasOverlappingControls: Bool {
        let boxes = [deleteButton.frame, archiveButton.frame, closeButton.frame]
            + swatchRects.map { $0.1 }
        for (i, a) in boxes.enumerated() {
            for b in boxes[(i + 1)...] where a.intersects(b.insetBy(dx: 0.5, dy: 0.5)) {
                return true
            }
        }
        guard let leftmostButton = [deleteButton, archiveButton, closeButton]
            .map(\.frame.minX).min(), let lastSwatch = swatchRects.last?.1 else { return false }
        return lastSwatch.maxX > leftmostButton
    }

    override func layout() {
        super.layout()
        for button in [deleteButton, archiveButton, closeButton] { button.scale = fitScale }
        var x = bounds.width
        for button in [closeButton, archiveButton, deleteButton] {
            let width = button.intrinsicContentSize.width
            x -= width
            button.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
            x -= 4
        }

        swatchRects = []
        guard showsSwatches else { return }
        var swatchX: CGFloat = 0
        for candidate in NoteColor.allCases {
            swatchRects.append((candidate, NSRect(x: swatchX,
                                                  y: (bounds.height - swatchSize) / 2,
                                                  width: swatchSize, height: swatchSize)))
            swatchX += swatchSize + swatchGap
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let found = swatchRects.first { $0.1.insetBy(dx: -3, dy: -3).contains(point) }?.0
        if found != hoveredSwatch { hoveredSwatch = found; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredSwatch = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let picked = swatchRects.first(where: { $0.1.insetBy(dx: -3, dy: -3).contains(point) })?.0
        else { return }
        // Not flashPress() on the whole row: the feedback for picking a colour
        // is the ring moving to it.
        color = picked
        onColor?(picked)
    }

    override func resetCursorRects() {
        for (_, rect) in swatchRects { addCursorRect(rect.insetBy(dx: -3, dy: -3), cursor: .pointingHand) }
    }

    override func draw(_ dirtyRect: NSRect) {
        for (candidate, rect) in swatchRects {
            let selected = candidate == color
            if selected {
                // A ring rather than a fill, so the chosen colour still shows.
                NSColor.black.withAlphaComponent(0.45).setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -2.5, dy: -2.5))
                ring.lineWidth = 1.2
                ring.stroke()
            }
            let inner = candidate == hoveredSwatch && !selected ? rect.insetBy(dx: -1, dy: -1) : rect
            Palette.paper(candidate, dark: false).setFill()
            NSBezierPath(ovalIn: inner).fill()
            Palette.tab(candidate).withAlphaComponent(0.55).setStroke()
            let edge = NSBezierPath(ovalIn: inner)
            edge.lineWidth = 1
            edge.stroke()
        }
    }
}

/// A quiet text button. Ledge has no window chrome to hang a toolbar off, so
/// these live on the paper itself.
final class ChromeButton: NSView {
    private(set) var title: String
    let destructive: Bool
    var onClick: (() -> Void)?

    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    init(title: String, destructive: Bool = false) {
        self.title = title
        self.destructive = destructive
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var scale: CGFloat = 1 { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    private var font: NSFont {
        .systemFont(ofSize: max(8, Metrics.Card.titleSize * 0.78 * scale), weight: .medium)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil((title as NSString).size(withAttributes: [.font: font]).width) + 13,
               height: 22)
    }

    /// What this button would measure before any squeezing.
    var unscaledWidth: CGFloat {
        let plain = NSFont.systemFont(ofSize: max(9, Metrics.Card.titleSize * 0.78), weight: .medium)
        return ceil((title as NSString).size(withAttributes: [.font: plain]).width) + 13
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

    func relabel(_ new: String) {
        guard new != title else { return }
        title = new
        setAccessibilityLabel(new)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { flashPress(); onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.isDark
        let ink = destructive
            ? NSColor.systemRed.blended(withFraction: dark ? 0.15 : 0.25, of: Palette.ink(dark: dark))!
            : Palette.ink(dark: dark)

        let box = bounds.insetBy(dx: 0, dy: 3)
        if hovering {
            ink.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        }
        ink.withAlphaComponent(0.22).setStroke()
        let border = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        border.lineWidth = 1
        border.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: ink.withAlphaComponent(hovering ? 1 : 0.78),
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                             y: (bounds.height - size.height) / 2),
                                 withAttributes: attributes)
    }
}
