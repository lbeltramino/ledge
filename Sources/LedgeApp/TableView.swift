import AppKit
import LedgeCore

/// A Markdown table, drawn.
///
/// The note still says what it always said — pipes and dashes — and this is
/// laid over the top of it while you are reading. The text underneath is made
/// invisible and given a fixed line height, so it reserves exactly the room
/// this needs. No glyph surgery, no attachment characters in the file: the
/// table is a view sitting on paper, and unlocking it simply takes the view
/// away and lets the text show through again.
final class TableView: NSView {
    var onUnlock: (() -> Void)?

    private var table: Tables.Table?
    private var widths: [CGFloat] = []
    private var rowHeights: [CGFloat] = []
    private var headerHeight: CGFloat = 0
    private var offset: CGFloat = 0
    private var hoveringLock = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    private var ink: NSColor = .black
    private var paper: NSColor = .white
    private var baseFont: NSFont = .systemFont(ofSize: 13)

    override var isFlipped: Bool { true }

    private var padding: CGFloat { max(6, baseFont.pointSize * 0.55) }
    private var lockSize: CGFloat { max(14, baseFont.pointSize * 1.15) }

    /// Never wider than this, whatever the content wants: past it a column is a
    /// paragraph, and the table stops being a table.
    private var maxColumn: CGFloat { max(120, baseFont.pointSize * 22) }

    // MARK: - measuring

    func configure(_ table: Tables.Table, font: NSFont, ink: NSColor, paper: NSColor,
                   available: CGFloat) {
        self.table = table
        self.baseFont = font
        self.ink = ink
        self.paper = paper

        let all = [table.header] + table.rows
        widths = (0..<table.columns).map { column in
            let widest = all.map { row -> CGFloat in
                let cell = column < row.count ? row[column] : ""
                return TableView.attributed(cell, font: font, ink: ink, bold: false).size().width
            }.max() ?? 0
            return min(maxColumn, max(44, widest + padding * 2))
        }

        // If the whole thing fits, spread the slack so it fills the note the
        // way a rendered table does rather than huddling on the left.
        let total = widths.reduce(0, +)
        if total < available, total > 0 {
            let slack = (available - total) / CGFloat(widths.count)
            widths = widths.map { $0 + slack }
        }

        headerHeight = height(of: table.header, bold: true)
        rowHeights = table.rows.map { height(of: $0, bold: false) }
        offset = 0
        needsDisplay = true
    }

    private func height(of row: [String], bold: Bool) -> CGFloat {
        let tallest = row.enumerated().map { index, cell -> CGFloat in
            let width = max(20, (index < widths.count ? widths[index] : 80) - padding * 2)
            let text = TableView.attributed(cell, font: baseFont, ink: ink, bold: bold)
            let box = text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                        options: [.usesLineFragmentOrigin, .usesFontLeading])
            return ceil(box.height)
        }.max() ?? baseFont.pointSize
        return max(baseFont.pointSize * 1.6, tallest + padding)
    }

    /// What the note has to make room for.
    var contentSize: NSSize {
        NSSize(width: widths.reduce(0, +), height: headerHeight + rowHeights.reduce(0, +))
    }

    var scrollRoom: CGFloat { max(0, contentSize.width - bounds.width) }
    var scrollOffset: CGFloat { offset }

    // MARK: - interaction

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

    private var lockRect: NSRect {
        NSRect(x: bounds.maxX - lockSize - 4, y: 3, width: lockSize, height: lockSize)
    }

    override func mouseMoved(with event: NSEvent) {
        let inside = lockRect.contains(convert(event.locationInWindow, from: nil))
        if inside != hoveringLock { hoveringLock = inside }
    }

    override func mouseExited(with event: NSEvent) { hoveringLock = false }

    override func mouseDown(with event: NSEvent) {
        // A click anywhere on a locked table is not an edit — it is either the
        // lock, or nothing. Letting it through would put the caret in the middle
        // of the pipes the table is hiding.
        if lockRect.contains(convert(event.locationInWindow, from: nil)) { onUnlock?() }
    }

    override func mouseUp(with event: NSEvent) {}

    override func scrollWheel(with event: NSEvent) {
        guard scrollRoom > 0 else {
            nextResponder?.scrollWheel(with: event)
            return
        }
        let sideways = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaX
            : event.deltaX * 10
        let updown = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 10
        // A trackpad swipes sideways; a wheel has only one axis, so shift makes
        // it the other one — which is what every app with a wide table does.
        let delta = abs(sideways) > abs(updown)
            ? sideways
            : (event.modifierFlags.contains(.shift) ? updown : 0)
        guard delta != 0 else {
            nextResponder?.scrollWheel(with: event)
            return
        }
        offset = max(0, min(offset - delta, scrollRoom))
        needsDisplay = true
    }

    func debugScroll(by delta: CGFloat) {
        offset = max(0, min(offset - delta, scrollRoom))
        needsDisplay = true
    }

    // MARK: - drawing

    /// Bold and `code`, which is what these tables are actually written with.
    /// Not a Markdown renderer — a cell is a phrase, and the two marks that
    /// appear in one are these.
    static func attributed(_ text: String, font: NSFont, ink: NSColor, bold: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var rest = Substring(text)
        let base = bold ? NSFont.boldSystemFont(ofSize: font.pointSize) : font

        func append(_ piece: String, font: NSFont, colour: NSColor) {
            out.append(NSAttributedString(string: piece, attributes: [.font: font, .foregroundColor: colour]))
        }

        while let start = rest.firstIndex(where: { $0 == "*" || $0 == "`" }) {
            let mark = rest[start]
            let opener = mark == "*" ? "**" : "`"
            let prefix = String(rest[rest.startIndex..<start])
            let after = rest[start...]
            guard after.hasPrefix(opener),
                  let closeRange = after.dropFirst(opener.count).range(of: opener) else {
                append(prefix + String(mark), font: base, colour: ink)
                rest = after.dropFirst()
                continue
            }
            append(prefix, font: base, colour: ink)
            let inner = String(after.dropFirst(opener.count)[..<closeRange.lowerBound])
            if mark == "*" {
                append(inner, font: .boldSystemFont(ofSize: font.pointSize), colour: ink)
            } else {
                append(inner, font: .monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: .regular),
                       colour: ink.withAlphaComponent(0.85))
            }
            rest = after[closeRange.upperBound...]
        }
        append(String(rest), font: base, colour: ink)
        return out
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let table else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }

        let line = ink.withAlphaComponent(0.18)
        let content = contentSize

        // The header band, the way a rendered table reads: a shade of the paper
        // rather than a colour of its own.
        (paper.blended(withFraction: 0.09, of: ink) ?? paper).setFill()
        NSRect(x: -offset, y: 0, width: content.width, height: headerHeight).fill()

        var y = headerHeight
        for height in rowHeights {
            line.setStroke()
            let rule = NSBezierPath()
            rule.lineWidth = 1
            rule.move(to: NSPoint(x: -offset, y: y))
            rule.line(to: NSPoint(x: -offset + content.width, y: y))
            rule.stroke()
            y += height
        }

        // Column rules and the outline.
        var x: CGFloat = -offset
        line.setStroke()
        for width in widths.dropLast() {
            x += width
            let rule = NSBezierPath()
            rule.lineWidth = 1
            rule.move(to: NSPoint(x: x, y: 0))
            rule.line(to: NSPoint(x: x, y: content.height))
            rule.stroke()
        }
        let outline = NSBezierPath(rect: NSRect(x: -offset + 0.5, y: 0.5,
                                                width: content.width - 1, height: content.height - 1))
        outline.lineWidth = 1
        outline.stroke()

        // The cells.
        drawRow(table.header, y: 0, height: headerHeight, bold: true, table: table)
        var rowY = headerHeight
        for (index, row) in table.rows.enumerated() {
            drawRow(row, y: rowY, height: rowHeights[index], bold: false, table: table)
            rowY += rowHeights[index]
        }

        drawEdgeFades()
        drawLock()
    }

    /// A fade at whichever edge has more table beyond it.
    ///
    /// The gesture works — two fingers sideways, or shift and the wheel — but
    /// nothing said the table continued, and a gesture nobody knows about is
    /// not a feature. This is the cue every app with a wide table uses.
    private func drawEdgeFades() {
        guard scrollRoom > 0 else { return }
        let width = min(26, bounds.width * 0.12)

        if offset > 0.5 {
            NSGradient(colors: [paper.withAlphaComponent(0.92), paper.withAlphaComponent(0)])?
                .draw(in: NSRect(x: 0, y: 0, width: width, height: bounds.height), angle: 0)
        }
        if offset < scrollRoom - 0.5 {
            NSGradient(colors: [paper.withAlphaComponent(0), paper.withAlphaComponent(0.92)])?
                .draw(in: NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height),
                      angle: 0)
        }
    }

    /// True when either edge is currently faded, so a check can say the cue is
    /// there rather than trusting that it was asked for.
    var showsMoreToTheRight: Bool { scrollRoom > 0 && offset < scrollRoom - 0.5 }
    var showsMoreToTheLeft: Bool { scrollRoom > 0 && offset > 0.5 }

    private func drawRow(_ row: [String], y: CGFloat, height: CGFloat, bold: Bool,
                         table: Tables.Table) {
        var x: CGFloat = -offset
        for (index, width) in widths.enumerated() {
            let cell = index < row.count ? row[index] : ""
            let text = TableView.attributed(cell, font: baseFont, ink: ink, bold: bold)
            let box = NSRect(x: x + padding, y: y + padding / 2,
                             width: max(10, width - padding * 2), height: height - padding / 2)
            let measured = text.boundingRect(with: NSSize(width: box.width, height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading])
            var origin = box
            switch index < table.alignment.count ? table.alignment[index] : .left {
            case .left: break
            case .centre: origin.origin.x += (box.width - measured.width) / 2
            case .right: origin.origin.x += box.width - measured.width
            }
            text.draw(with: origin, options: [.usesLineFragmentOrigin, .usesFontLeading])
            x += width
        }
    }

    /// A padlock, closed. Pressing it hands the note back its text.
    private func drawLock() {
        let box = lockRect
        (paper.blended(withFraction: hoveringLock ? 0.18 : 0.10, of: ink) ?? paper).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()

        let colour = ink.withAlphaComponent(hoveringLock ? 0.75 : 0.42)
        colour.setStroke()
        let body = NSRect(x: box.minX + box.width * 0.28, y: box.minY + box.height * 0.46,
                          width: box.width * 0.44, height: box.height * 0.34)
        let shackle = NSBezierPath()
        shackle.lineWidth = 1.3
        shackle.appendArc(withCenter: NSPoint(x: body.midX, y: body.minY),
                          radius: body.width * 0.34, startAngle: 0, endAngle: 180)
        shackle.stroke()
        colour.setFill()
        NSBezierPath(roundedRect: body, xRadius: 1.5, yRadius: 1.5).fill()
    }
}
