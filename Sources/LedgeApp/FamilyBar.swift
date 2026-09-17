import AppKit
import LedgeCore
import LedgeIndex

/// What a note keeps, and what keeps it: the row above the colours.
///
/// On a note with children it lists them; on a child it shows the way back to
/// its mother and the button that takes it out to the strip. One row either
/// way, because a note is either a folder or a sheet in one — never both, and
/// never worth two rows of chrome on a sticky note.
final class FamilyBar: NSView {

    static let height: CGFloat = 22

    var onOpen: ((String) -> Void)?
    /// Out to the strip, or back into the folder.
    var onToggleStrip: ((Bool) -> Void)?

    private var chips: [(id: String?, rect: NSRect, label: String, colour: NoteColor?)] = []
    private var labels: [(rect: NSRect, text: String)] = []
    private var hovered: Int?
    private var tracking: NSTrackingArea?

    /// The mother, when this is a child.
    private var mother: (id: String, title: String)?
    private var children: [NoteRecord] = []
    private var isOut = false

    var ink: NSColor = .labelColor { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    func show(children: [NoteRecord], mother: (id: String, title: String)?, isOnStrip: Bool) {
        self.children = children
        self.mother = mother
        self.isOut = isOnStrip
        isHidden = children.isEmpty && mother == nil
        needsLayout = true
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func layout() {
        super.layout()
        chips = []
        labels = []
        var x: CGFloat = 0
        let pad: CGFloat = 7
        let gap: CGFloat = 5

        /// Not a chip: a word, so the row reads as a sentence about the note.
        func addLabel(_ text: String) {
            let width = ceil(Self.measure(text, font: Self.labelFont) + 6)
            guard x + width <= bounds.width else { return }
            labels.append((NSRect(x: x, y: 0, width: width, height: Self.height), text))
            x += width + 3
        }

        func add(_ label: String, id: String?, colour: NoteColor?) {
            let width = ceil(Self.measure(label) + pad * 2 + (colour != nil ? 12 : 0))
            guard x + width <= bounds.width else { return }
            chips.append((id, NSRect(x: x, y: 0, width: width, height: Self.height), label, colour))
            x += width + gap
        }

        // A word in front, because a chip on its own does not say what it is.
        // Reported exactly that way: "what is this Hol button?"
        if !children.isEmpty, mother == nil { addLabel("Contiene") }
        if let mother {
            add("‹ " + mother.title, id: mother.id, colour: nil)
            // The way out, on the child itself, where you can see what you are
            // letting loose.
            add(isOut ? "Guardar en la carpeta" : "Sacar a la tira", id: nil, colour: nil)
        }
        for child in children { add(child.displayTitle, id: child.id, colour: child.color) }
    }

    private static func measure(_ label: String, font: NSFont = FamilyBar.font) -> CGFloat {
        (label as NSString).size(withAttributes: [.font: font]).width
    }
    private static let font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
    private static let labelFont = NSFont.systemFont(ofSize: 9.5, weight: .medium)

    override func draw(_ dirtyRect: NSRect) {
        for label in labels {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.labelFont,
                .foregroundColor: ink.withAlphaComponent(0.45),
            ]
            let size = (label.text as NSString).size(withAttributes: attributes)
            (label.text as NSString).draw(at: NSPoint(x: label.rect.minX,
                                                      y: label.rect.midY - size.height / 2),
                                          withAttributes: attributes)
        }
        for (i, chip) in chips.enumerated() {
            let lifted = hovered == i
            ink.withAlphaComponent(lifted ? 0.16 : 0.09).setFill()
            NSBezierPath(roundedRect: chip.rect, xRadius: 4, yRadius: 4).fill()

            var textX = chip.rect.minX + 7
            if let colour = chip.colour {
                let dot = NSRect(x: textX, y: chip.rect.midY - 3.5, width: 7, height: 7)
                Palette.tab(colour).setFill()
                NSBezierPath(roundedRect: dot, xRadius: 2, yRadius: 2).fill()
                textX += 12
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.font,
                .foregroundColor: ink.withAlphaComponent(lifted ? 0.95 : 0.72),
            ]
            let size = (chip.label as NSString).size(withAttributes: attributes)
            (chip.label as NSString).draw(at: NSPoint(x: textX, y: chip.rect.midY - size.height / 2),
                                          withAttributes: attributes)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let found = chips.firstIndex { $0.rect.contains(point) }
        if found != hovered { hovered = found; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil { hovered = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        press(at: convert(event.locationInWindow, from: nil))
    }

    /// Split out from `mouseDown` so a check can press a chip where it is drawn
    /// rather than assert about rectangles and hope the two agree.
    func press(at point: NSPoint) {

        guard let chip = chips.first(where: { $0.rect.contains(point) }) else { return }
        if let id = chip.id { onOpen?(id) } else { onToggleStrip?(!isOut) }
    }

    override func resetCursorRects() {
        for chip in chips { addCursorRect(chip.rect, cursor: .pointingHand) }
    }

    var debugChips: [(String?, NSRect, String)] { chips.map { ($0.id, $0.rect, $0.label) } }
    var debugLabels: [String] { chips.map(\.label) }
    var debugWords: [String] { labels.map(\.text) }
}
