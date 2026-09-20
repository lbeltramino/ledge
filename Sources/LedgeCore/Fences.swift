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

    /// The tag on the fence that opens the block a caret sits in — `mermaid`,
    /// `json`, `log` — or nil when the caret is not inside one.
    ///
    /// Lowercased and trimmed, because a tag is a name and not a spelling.
    public static func tag(at location: Int, in text: NSString) -> String? {
        guard let block = ranges(in: text).first(where: { NSLocationInRange(location, $0) })
        else { return nil }
        let opening = text.lineRange(for: NSRange(location: block.location, length: 0))
        // The caret on the opening line is not yet inside the block: the tag is
        // still being typed.
        guard location >= NSMaxRange(opening) else { return nil }
        let line = text.substring(with: opening).trimmingCharacters(in: .whitespacesAndNewlines)
        let ticks = line.prefix { $0 == "`" || $0 == "~" }.count
        return String(line.dropFirst(ticks)).trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Is this range inside a block where Markdown does not apply?
    public static func contains(_ range: NSRange, in text: NSString) -> Bool {
        ranges(in: text).contains { NSIntersectionRange($0, range).length > 0 }
    }

    /// The same question for a caret, which has no length of its own.
    ///
    /// Also true inside a block that has been opened and not yet closed —
    /// which is the usual state of a block while somebody is typing one, and
    /// exactly when offering to link a note would be most unwelcome. Counted
    /// rather than matched: an odd number of fence lines before the caret means
    /// it is inside one.
    public static func containsCaret(_ location: Int, in text: NSString) -> Bool {
        if ranges(in: text).contains(where: { NSLocationInRange(location, $0) }) { return true }
        return marks(before: location, in: text) % 2 == 1
    }

    private static let markRegex = try? NSRegularExpression(pattern: "^(```|~~~)",
                                                            options: [.anchorsMatchLines])

    private static func marks(before location: Int, in text: NSString) -> Int {
        guard let markRegex, location > 0 else { return 0 }
        return markRegex.numberOfMatches(in: text as String,
                                         range: NSRange(location: 0, length: min(location, text.length)))
    }
}
