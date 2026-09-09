import AppKit

/// The mark on a task that is under way.
///
/// A tick with only its first stroke drawn. The mark is literally unfinished,
/// which is the whole idea: nothing to learn, nothing to look up. `[x]` gets a
/// full tick from the strikethrough and the receding text; `[/]` gets half of
/// one, in the note's accent, and its text stays at full strength — so on any
/// note exactly one line leans forward.
///
/// The `/` glyph underneath is painted out and this is drawn in its place. The
/// file still says `/`: copy the line anywhere else and it is `- [/] …`, which
/// is what Obsidian writes and what every other viewer shows as plain text.
enum ProgressTick {
    static let attribute = NSAttributedString.Key("ledge.doing")

    /// `box` is the rectangle of the single `/` character.
    static func draw(in box: NSRect, colour: NSColor) {
        // The short arm of a tick: down and to the right. The view is flipped,
        // so down is +y.
        let stroke = NSBezierPath()
        stroke.move(to: NSPoint(x: box.minX + box.width * 0.20,
                                y: box.minY + box.height * 0.44))
        stroke.line(to: NSPoint(x: box.minX + box.width * 0.52,
                                y: box.minY + box.height * 0.72))
        stroke.lineWidth = max(1.3, box.height * 0.09)
        stroke.lineCapStyle = .round
        colour.setStroke()
        stroke.stroke()
    }
}
