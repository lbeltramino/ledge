import Foundation

/// `[[Another note]]`.
///
/// The index already knows every title and can search every body; linking is
/// what turns a drawer of notes into something that accumulates.
public enum Wikilink {

    public static let pattern = "\\[\\[([^\\]\\[\\n]+)\\]\\]"

    private static let regex = try? NSRegularExpression(pattern: pattern)

    public struct Link: Equatable, Sendable {
        /// Including the brackets.
        public let range: NSRange
        /// Just the name.
        public let nameRange: NSRange
        public let name: String
    }

    public static func links(in text: String) -> [Link] {
        guard let regex else { return [] }
        let source = text as NSString
        // `[[ -f "$f" ]]` in a shell block is a test, not a link to a note
        // called `-f "$f"`. Without this the highlighter underlined half of
        // every bash snippet and ⌘-click offered to open it.
        let fenced = Fences.ranges(in: source)
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length))
            .filter { match in
                !fenced.contains { NSIntersectionRange($0, match.range).length > 0 }
            }
            .map { match in
                Link(range: match.range, nameRange: match.range(at: 1),
                     name: source.substring(with: match.range(at: 1))
                         .trimmingCharacters(in: .whitespaces))
            }
    }

    public static func names(in text: String) -> [String] {
        links(in: text).map(\.name)
    }

    /// The link under `index`, if there is one.
    public static func link(in text: String, at index: Int) -> Link? {
        links(in: text).first { NSLocationInRange(index, $0.range) }
    }

    // MARK: - a link being typed

    /// A `[[` that has been opened and not yet closed, with the caret inside it.
    public struct Opening: Equatable, Sendable {
        /// From the first bracket to the caret — what a picked name replaces.
        public let range: NSRange
        /// What has been typed since the brackets.
        public let query: String
    }

    /// Is somebody typing a link right now?
    ///
    /// Looks back from the caret to a `[[` on the same line, with no `]]` in
    /// between. Nil inside a fenced block: `[[ -f "$f" ]]` is a shell test, and
    /// offering to link a note in the middle of a script would be worse than
    /// offering nothing.
    public static func opening(in text: String, at caret: Int) -> Opening? {
        let source = text as NSString
        guard caret >= 2, caret <= source.length else { return nil }
        guard !Fences.containsCaret(caret, in: source) else { return nil }

        let line = source.lineRange(for: NSRange(location: min(caret, source.length - 1), length: 0))
        let before = source.substring(with: NSRange(location: line.location,
                                                    length: caret - line.location))
        guard let open = before.range(of: "[[", options: .backwards) else { return nil }
        let query = String(before[open.upperBound...])
        // `]]` between the brackets and the caret means that link is finished
        // and this caret is merely after it.
        guard !query.contains("]"), !query.contains("[") else { return nil }

        let start = line.location + before.distance(from: before.startIndex, to: open.lowerBound)
        return Opening(range: NSRange(location: start, length: caret - start), query: query)
    }

    /// Case, accents and surrounding space ignored — the same match the command
    /// uses when an agent quotes a title back at it.
    public static func matches(_ query: String, in titles: [String], limit: Int = 6) -> [String] {
        let needle = fold(query)
        guard !needle.isEmpty else { return Array(titles.prefix(limit)) }
        let scored = titles.compactMap { title -> (String, Int)? in
            let hay = fold(title)
            guard let found = hay.range(of: needle) else { return nil }
            // A title that starts with what you typed comes first; after that,
            // the shorter one, because it is the more exact answer.
            let atStart = found.lowerBound == hay.startIndex ? 0 : 1
            return (title, atStart * 1000 + title.count)
        }
        return scored.sorted { $0.1 < $1.1 }.map(\.0).prefix(limit).map { $0 }
    }

    /// Does a note by this name already exist?
    public static func exists(_ query: String, in titles: [String]) -> Bool {
        let needle = fold(query)
        return !needle.isEmpty && titles.contains { fold($0) == needle }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
