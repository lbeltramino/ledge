import AppKit

/// The marker, offered where you are using it.
///
/// `⌘⇧H` has always wrapped a selection in `==`, and nobody who had not read
/// the README knew that. This is the same command with somewhere to find it: a
/// small pen that appears over a selection and puts the marks in for you. The
/// note keeps saying `==like this==`, so a highlight made with the mouse and one
/// typed by hand are the same file.
///
/// Drawn as a swipe of the note's own highlighter rather than an icon of one,
/// which is both the honest picture and free — the drawing already exists.
final class HighlightBar: NSView {
    var onClick: (() -> Void)?
    /// The colour this note highlights in.
    var pen: NSColor = .systemYellow
    var seed: String = ""

    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    static let size = NSSize(width: 34, height: 26)

    init() {
        super.init(frame: NSRect(origin: .zero, size: HighlightBar.size))
        shadow = DeckControlStyle.shadow()
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Never. Taking focus would drop the selection this exists to act on.
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    // Both halves are swallowed: a click here must not move the caret, which
    // would throw away the selection before the command could run.
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func mouseUp(with event: NSEvent) {}

    override func draw(_ dirtyRect: NSRect) {
        let plate = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        (hovering ? DeckControlStyle.fillHovering : DeckControlStyle.fill).setFill()
        plate.fill()

        // A stroke of the real pen, in the real colour, drawn by the code that
        // draws the real thing.
        let swipe = bounds.insetBy(dx: 7, dy: 8)
        MarkerStroke.draw(in: swipe, colour: pen, seed: seed.isEmpty ? "bar" : seed, index: 7)
    }
}
