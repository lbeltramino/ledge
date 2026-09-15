import Foundation

/// Where the fenced code blocks are.
///
/// Inside one, Markdown stops being Markdown. A `# comment` is a comment, and
/// `[[ -f "$f" ]]` is a shell test rather than a link to a note called `-f "$f"`
/// — which matters in an app that goes out of its way to make pasting scripts
/// easy, and matters more once typing `[[` offers to link something.
///
/// One implementation, because two would drift: the headings index and the
/// links both ask this.
public enum Fences {

    private static let regex = try? NSRegularExpression(
        pattern: "^(```|~~~)[^\n]*\n[\\s\\S]*?^\\1[ \t]*$",
        options: [.anchorsMatchLines])

    public static func ranges(in text: NSString) -> [NSRange] {
        guard let regex else { return [] }
        return regex.matches(in: text as String,
                             range: NSRange(location: 0, length: text.length))
            .map(\.range)
    }

    public static func ranges(in text: String) -> [NSRange] { ranges(in: text as NSString) }

    /// Is this range inside a block where Markdown does not apply?
    public static func contains(_ range: NSRange, in text: NSString) -> Bool {
        ranges(in: text).contains { NSIntersectionRange($0, range).length > 0 }
    }

    /// The same question for a caret, which has no length of its own.
    public static func containsCaret(_ location: Int, in text: NSString) -> Bool {
        ranges(in: text).contains { NSLocationInRange(location, $0) }
    }
}
