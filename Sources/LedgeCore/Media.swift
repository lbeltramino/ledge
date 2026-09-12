import Foundation

/// Pictures and diagrams a note points at: where the markdown is, and what it
/// asks for.
///
/// Only the reading lives here — no decoding, no measuring, no drawing, and no
/// idea that a screen or a disk exists. Same bargain as `Tables`: what a note
/// asks for is something the checks can reason about without either.
public enum Media {

    public enum Kind: Equatable, Sendable {
        /// `![alt](resources/img/thing.png)` — a path, always relative to the
        /// notes folder and always local. See `isLocal`.
        case image(path: String)
        /// A ```` ```mermaid ```` block: the source between the fences.
        case diagram(source: String)
    }

    public struct Item: Equatable, Sendable {
        /// The markdown this stands for. The text stays in the note and stays
        /// visible — the drawing goes underneath it, so a note is still the
        /// file you would read in any other editor.
        public let range: NSRange
        public let kind: Kind
        public let alt: String

        public init(range: NSRange, kind: Kind, alt: String) {
            self.range = range
            self.kind = kind
            self.alt = alt
        }
    }

    /// A path Ledge will open. Anything with a scheme is somebody else's
    /// server: the app has never made a network request, and an image
    /// reference is not the place to start — a note that quietly phoned a host
    /// when you opened it would be a different kind of app. Those references
    /// are left as plain markdown.
    public static func isLocal(_ path: String) -> Bool {
        let lower = path.lowercased()
        guard !lower.hasPrefix("http://"), !lower.hasPrefix("https://"),
              !lower.hasPrefix("data:"), !lower.hasPrefix("file://") else { return false }
        // No climbing out of the notes folder, and no absolute paths: a note is
        // a file someone might have been handed.
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        return !path.components(separatedBy: "/").contains("..")
    }

    private static let imagePattern = #"^!\[([^\]]*)\]\(([^)\s]+)\)$"#
    private static let imageRegex = try? NSRegularExpression(pattern: imagePattern)

    public static func all(in text: String) -> [Item] {
        let lines = text.components(separatedBy: "\n")
        var starts: [Int] = []
        var offset = 0
        for line in lines {
            starts.append(offset)
            offset += (line as NSString).length + 1
        }

        var found: [Item] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // A fenced mermaid block, drawn from the source between the fences.
            if isDiagramFence(trimmed) {
                var end = index + 1
                while end < lines.count,
                      lines[end].trimmingCharacters(in: .whitespaces) != "```" {
                    end += 1
                }
                // An unterminated fence is someone in the middle of typing one,
                // not a diagram. Nothing is drawn until they close it.
                if end < lines.count {
                    let source = lines[(index + 1)..<end].joined(separator: "\n")
                    let last = starts[end] + (lines[end] as NSString).length
                    if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        found.append(Item(range: NSRange(location: starts[index],
                                                         length: last - starts[index]),
                                          kind: .diagram(source: source),
                                          alt: "diagram"))
                    }
                    index = end + 1
                    continue
                }
            }

            // An image on a line of its own. Inline ones — a picture in the
            // middle of a sentence — stay as they are: a note is a sticky note,
            // and text flowing around a picture is a page layout.
            if let match = imageRegex?.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               match.numberOfRanges == 3,
               let altRange = Range(match.range(at: 1), in: trimmed),
               let pathRange = Range(match.range(at: 2), in: trimmed) {
                let path = String(trimmed[pathRange])
                if isLocal(path) {
                    found.append(Item(range: NSRange(location: starts[index],
                                                     length: (line as NSString).length),
                                      kind: .image(path: path),
                                      alt: String(trimmed[altRange])))
                }
            }
            index += 1
        }
        return found
    }

    private static func isDiagramFence(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("```") else { return false }
        let tag = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
        return tag == "mermaid"
    }

    /// Where a note's pictures live: one folder beside the notes, so the whole
    /// thing is still something you can copy, sync or hand to somebody as a
    /// directory. Referenced from a note as `resources/img/…`.
    public static let folder = "resources/img"
}
