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
    private var swatchSize: CGFloat { max(10, Metrics.Card.titleSize * 0.95) }
    private var swatchGap: CGFloat { max(5, Metrics.Card.titleSize * 0.5) }

    /// The narrowest this row can be drawn without its controls colliding.
    /// The card refuses to be narrower than this, which is why Delete no longer
    /// lands on top of the colour swatches.
    var minimumWidth: CGFloat {
        let swatches = CGFloat(NoteColor.allCases.count) * (swatchSize + swatchGap)
        let buttons = [deleteButton, archiveButton, closeButton]
            .reduce(CGFloat(0)) { $0 + $1.intrinsicContentSize.width + 4 }
        return ceil(swatches + buttons + 6)
    }

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

    override func layout() {
        super.layout()
        var x = bounds.width
        for button in [closeButton, archiveButton, deleteButton] {
            let width = button.intrinsicContentSize.width
            x -= width
            button.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
            x -= 4
        }

        swatchRects = []
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

    private var font: NSFont { .systemFont(ofSize: max(9, Metrics.Card.titleSize * 0.78), weight: .medium) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil((title as NSString).size(withAttributes: [.font: font]).width) + 13,
               height: 22)
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
    override func mouseDown(with event: NSEvent) { onClick?() }
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
