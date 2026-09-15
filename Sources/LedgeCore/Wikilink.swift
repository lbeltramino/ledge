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
}
