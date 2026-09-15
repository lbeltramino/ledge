import AppKit
import LedgeCore

/// The notes you could mean, while you are typing `[[`.
///
/// Small, anchored under the caret, and never in the way: it offers, it does
/// not ask. Nothing is created by typing — the last row says what would be
/// made, and only pressing it makes it.
///
/// Drawn rather than assembled from a table view, for the same reason the rest
/// of this app is: it sits on paper.
final class LinkPicker: NSView {

    /// An existing note was picked.
    var onPick: ((String) -> Void)?
    /// The row that makes one. `asChild` is false when Shift was held: a note
    /// of its own, with a tab, rather than one kept inside this note.
    var onCreate: ((String, _ asChild: Bool) -> Void)?

    private(set) var titles: [String] = []
    private var query = ""
    private var canCreate = false
    private var selection = 0
    private var paper: NSColor = .white
    private var ink: NSColor = .black

    private var rowHeight: CGFloat { max(17, Metrics.Card.titleSize * 1.35) }
    private var font: NSFont { .systemFont(ofSize: Metrics.Card.titleSize * 0.82) }
    static let maximumWidth: CGFloat = 230

    /// Every row: the notes, then the one that would be created.
    private var rows: Int { titles.count + (canCreate ? 1 : 0) }

    var isOpen: Bool { !isHidden && rows > 0 }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(query: String, titles: [String], canCreate: Bool, paper: NSColor, ink: NSColor) {
        self.query = query
        self.titles = titles
        self.canCreate = canCreate
        self.paper = paper
        self.ink = ink
        selection = min(selection, max(0, rows - 1))
        isHidden = rows == 0
        layer?.backgroundColor = paper.blended(withFraction: 0.5, of: .white)?.cgColor
            ?? paper.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = ink.withAlphaComponent(0.14).cgColor
        needsDisplay = true
    }

    func close() {
        isHidden = true
        selection = 0
        titles = []
        canCreate = false
    }

    var size: NSSize {
        NSSize(width: Self.maximumWidth, height: CGFloat(rows) * rowHeight + 8)
    }

    // MARK: - keyboard, while it is open

    func move(by delta: Int) {
        guard rows > 0 else { return }
        selection = (selection + delta + rows) % rows
        needsDisplay = true
    }

    /// Takes the highlighted row. True when it did something.
    @discardableResult
    func take(shift: Bool = false) -> Bool {
        guard rows > 0 else { return false }
        if selection < titles.count { onPick?(titles[selection]) }
        else { onCreate?(query.trimmingCharacters(in: .whitespaces), !shift) }
        close()
        return true
    }

    // MARK: - drawing

    override func draw(_ dirtyRect: NSRect) {
        for row in 0..<rows {
            let rect = NSRect(x: 1, y: 4 + CGFloat(row) * rowHeight,
                              width: max(0, bounds.width - 2), height: rowHeight)
            if row == selection {
                ink.withAlphaComponent(0.11).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 1), xRadius: 4, yRadius: 4).fill()
            }
            let creating = row >= titles.count
            let label = creating ? "Crear “\(query.trimmingCharacters(in: .whitespaces))”" : titles[row]
            let attributes: [NSAttributedString.Key: Any] = [
                .font: creating ? NSFont.systemFont(ofSize: font.pointSize, weight: .semibold) : font,
                .foregroundColor: ink.withAlphaComponent(creating ? 0.72 : 0.9),
            ]
            let text = label as NSString
            let room = rect.width - 20
            var drawn = text
            if text.size(withAttributes: attributes).width > room {
                var cut = label
                while !cut.isEmpty, (cut + "…" as NSString).size(withAttributes: attributes).width > room {
                    cut.removeLast()
                }
                drawn = (cut + "…") as NSString
            }
            drawn.draw(at: NSPoint(x: rect.minX + 9,
                                   y: rect.midY - font.pointSize * 0.72),
                       withAttributes: attributes)
        }

        // The hint, only on the row that would make a note — the place where
        // the choice actually exists.
        if canCreate, selection >= titles.count {
            let hint = "⏎ dentro de esta nota · ⇧⏎ suelta"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: max(8, font.pointSize * 0.72)),
                .foregroundColor: ink.withAlphaComponent(0.42),
            ]
            let size = (hint as NSString).size(withAttributes: attributes)
            (hint as NSString).draw(at: NSPoint(x: bounds.width - size.width - 9,
                                                y: 4 + CGFloat(selection) * rowHeight
                                                   + rowHeight / 2 - size.height / 2),
                                    withAttributes: attributes)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = Int((point.y - 4) / rowHeight)
        if row >= 0, row < rows, row != selection { selection = row; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = Int((point.y - 4) / rowHeight)
        guard row >= 0, row < rows else { return }
        selection = row
        take(shift: event.modifierFlags.contains(.shift))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    var debugRows: [String] {
        titles + (canCreate ? ["Crear “\(query.trimmingCharacters(in: .whitespaces))”"] : [])
    }
    var debugSelection: Int { selection }
}
