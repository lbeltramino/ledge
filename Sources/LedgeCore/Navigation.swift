import Foundation

/// Where the caret goes when you press Home or End.
///
/// macOS sends those keys to `scrollToBeginningOfDocument:` — the page moves
/// and the caret stays where it was. That is the platform convention and it is
/// not what anyone who writes code expects, so this works out the answer an
/// editor would give and the view puts the caret there.
///
/// Here rather than in the view because it is arithmetic over text, and
/// arithmetic over text is something a check can read without a window.
public enum Navigation {

    /// Home: the first character that is not a blank, and column zero when you
    /// are already on it.
    ///
    /// Two stops rather than one, the way VS Code does it. On a note this is
    /// worth more than it sounds: almost every line that matters — a task, a
    /// nested list item, a line inside a fenced block — starts with indentation,
    /// and column zero is almost never where you wanted to be.
    public static func lineStart(in text: String, from caret: Int) -> Int {
        let source = text as NSString
        guard source.length > 0 else { return 0 }
        let caret = min(max(0, caret), source.length)
        let line = source.lineRange(for: NSRange(location: min(caret, source.length - 1), length: 0))

        var firstInk = line.location
        while firstInk < NSMaxRange(line) {
            let ch = source.substring(with: NSRange(location: firstInk, length: 1))
            if ch != " " && ch != "\t" { break }
            firstInk += 1
        }
        // A blank line has no ink: its two stops are the same place.
        if firstInk >= NSMaxRange(line) { firstInk = line.location }

        return caret == firstInk ? line.location : firstInk
    }

    /// End: the last character of the line, never the newline that ends it —
    /// landing on the next line would be the opposite of what was asked for.
    public static func lineEnd(in text: String, from caret: Int) -> Int {
        let source = text as NSString
        guard source.length > 0 else { return 0 }
        let caret = min(max(0, caret), source.length)
        let line = source.lineRange(for: NSRange(location: min(caret, source.length - 1), length: 0))
        var end = NSMaxRange(line)
        while end > line.location {
            let ch = source.substring(with: NSRange(location: end - 1, length: 1))
            if ch != "\n" && ch != "\r" { break }
            end -= 1
        }
        return end
    }
}
