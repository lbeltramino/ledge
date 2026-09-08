import Foundation

/// Tags are written where you write everything else: in the note.
///
/// `#work` is a tag. `# Heading` is a heading — the space is what tells them
/// apart, and it is the same rule the Markdown highlighter already uses.
public enum Tags {

    /// `#` followed by a letter, then letters, digits, `-`, `_` or `/`.
    /// Not preceded by a word character, so `C#` and `foo#bar` are not tags.
    public static let pattern = "(?<![\\w#])#([\\p{L}][\\p{L}\\p{N}_/-]*)"

    private static let regex = try? NSRegularExpression(pattern: pattern)

    /// Every tag written in a piece of text, lowercased, in first-seen order.
    public static func found(in text: String) -> [String] {
        guard let regex else { return [] }
        let source = text as NSString
        var seen = Set<String>()
        var out: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let tag = source.substring(with: match.range(at: 1)).lowercased()
            if seen.insert(tag).inserted { out.append(tag) }
        }
        return out
    }

    /// The ranges of the whole `#tag`, for highlighting.
    public static func ranges(in text: String) -> [NSRange] {
        guard let regex else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length))
            .map(\.range)
    }

    /// Reconciles a note's tag list after an edit.
    ///
    /// Adding `#work` to the body adds the tag; removing it removes the tag.
    /// A tag written by hand into the frontmatter, and never in any body,
    /// survives — Ledge did not put it there and does not get to take it away.
    public static func merged(existing: [String], oldBody: String, newBody: String) -> [String] {
        let before = Set(found(in: oldBody))
        let after = found(in: newBody)
        let removed = before.subtracting(after)

        var result = existing.filter { !removed.contains($0) }
        for tag in after where !result.contains(tag) { result.append(tag) }
        return result
    }
}
