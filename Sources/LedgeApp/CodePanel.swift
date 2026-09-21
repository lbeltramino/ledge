import AppKit
import LedgeCore

/// The panel a fenced block sits on, and the numbers down its left.
///
/// Drawn, not a background colour on every character. That was the mistake the
/// first attempt made: a gutter has to live somewhere, and making room for it
/// by indenting the text puts it inside the region a background attribute
/// paints — so the panel's left edge and the gutter's left edge are the same
/// number, decided in two places, and they disagree. Every editor avoids this
/// by giving the gutter a surface of its own; here that surface is the panel,
/// and the panel is one rounded rectangle this view fills.
///
/// So the numbers are always on the panel, by construction, whatever the
/// indent happens to be — there is nothing left to keep in step.
enum CodePanel {

    /// Marks a fenced block, so the view knows what to draw a panel under.
    static let attribute = NSAttributedString.Key("ledge.panel")
    /// Marks one that is long enough to be numbered.
    static let numbered = NSAttributedString.Key("ledge.numbered")

    /// Numbers start at five lines.
    ///
    /// The same bargain the outline makes by appearing only at two headings:
    /// chrome is earned. Two lines of `kubectl` with numbers beside them look
    /// like an IDE, and this is a sticky note.
    static let minimumLines = 5

    /// The panel's own padding, and where the text starts without numbers.
    static let inset: CGFloat = 10
    static let radius: CGFloat = 6

    static func numbers(forBodyOf body: String) -> Bool {
        lineCount(of: body) >= minimumLines
    }

    /// Lines in a block's body, not counting a trailing empty one — a body
    /// always ends in the newline before its closing fence.
    static func lineCount(of body: String) -> Int {
        var lines = body.components(separatedBy: "\n")
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines.count
    }

    /// The column the numbers are drawn in: wide enough for three digits,
    /// which is more lines than a sticky note will ever hold, so it never
    /// changes width as you type and the code never shifts sideways.
    static func gutterWidth(for font: NSFont) -> CGFloat {
        ceil(("000" as NSString).size(withAttributes: [.font: font]).width) + 8
    }

    /// Where the code starts: past the panel's padding, and past the numbers
    /// when there are any.
    static func textIndent(for font: NSFont, numbered: Bool) -> CGFloat {
        numbered ? inset + gutterWidth(for: font) : inset
    }

    static func fill(_ rect: NSRect, ink: NSColor) {
        ink.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }
}
