import AppKit

/// The rule down the side of a quote.
///
/// Drawn rather than set as a border, for the same reason the highlighter's
/// marker is drawn rather than filled: a border attribute is a rectangle around
/// every line and would read as a selection. This is one stroke down the whole
/// quote, however many lines it runs to.
///
/// In the note's accent, so it is a different colour on each of the five
/// papers — and quieter than the words, because a quote is something somebody
/// else said and not a headline.
enum QuoteBar {

    /// Put on a quoted line by the highlighter; read by the text view when it
    /// draws. The two never have to agree about what a quote *is*, only about
    /// this key.
    static let attribute = NSAttributedString.Key("ledge.quote")

    /// How far in from the text container the stroke sits, and how thick.
    static let offset: CGFloat = 3
    static let thickness: CGFloat = 2

    static func draw(in box: NSRect, colour: NSColor) {
        let bar = NSRect(x: box.minX + offset, y: box.minY,
                         width: thickness, height: box.height)
        colour.setFill()
        NSBezierPath(roundedRect: bar, xRadius: thickness / 2, yRadius: thickness / 2).fill()
    }
}
