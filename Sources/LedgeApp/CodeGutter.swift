import AppKit
import LedgeCore

/// The strip down the left of a fenced block: line numbers, or the column a
/// log's times live in.
///
/// One place decides how wide it is, because two things depend on the same
/// number and they are written in different files — the highlighter indents the
/// text by it, and the text view draws inside it. A gutter and an indent that
/// disagree is a column of numbers sitting on top of the code.
enum CodeGutter {

    /// Marks a block that is drawn with numbers, so the view does not have to
    /// work out again what the highlighter already decided.
    static let attribute = NSAttributedString.Key("ledge.gutter")

    /// Numbers start at five lines.
    ///
    /// The same bargain the outline makes by appearing only at two headings:
    /// chrome is earned. Two lines of `kubectl` with numbers beside them look
    /// like an IDE, and this is a sticky note.
    static let minimumLines = 5

    /// The left edge of a fenced block, matching what the fenced rule uses.
    static let inset: CGFloat = 10

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

    /// How wide the widest number will be drawn, plus its breathing room.
    static func numberWidth(for font: NSFont, lines: Int) -> CGFloat {
        let digits = String(max(lines, 10)).count
        let sample = String(repeating: "0", count: digits) as NSString
        return ceil(sample.size(withAttributes: [.font: font]).width) + 10
    }

    /// Where the code starts in a numbered block.
    static func textIndent(for font: NSFont, lines: Int = 99) -> CGFloat {
        inset + numberWidth(for: font, lines: lines)
    }

    /// Where the prose starts in a log block: past the widest time.
    static func logIndent(for font: NSFont) -> CGFloat {
        inset + ceil((Log.widestTime as NSString).size(withAttributes: [.font: font]).width)
    }
}
