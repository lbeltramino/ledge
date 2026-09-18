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
        /// A block of JSON with a JSONForms `uiSchema` somewhere in it, drawn
        /// as the form it describes. The source is the whole block: finding the
        /// uiSchema inside it is `UISchema`'s job, not this one's.
        case form(source: String)

        /// Whether this lives in a fenced block, which is what gives it
        /// somewhere to hang a mark when it is too tall to be drawn.
        public var isFenced: Bool {
            switch self {
            case .diagram, .form: return true
            case .image: return false
            }
        }
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
            // Newlines as well as spaces: a file with CRLF endings leaves a
            // carriage return on the end of every line, and "```json\r" is not
            // "```json". Nothing here would have drawn in such a file.
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // A fenced block that draws something: mermaid, or JSON with a
            // form in it.
            if let fence = drawableFence(trimmed) {
                // Closed by a run of backticks at least as long as the one that
                // opened it, which is what CommonMark says and what `Code`
                // writes: a snippet containing a line of backticks is fenced in
                // four or more, and looking for exactly three never found the
                // end of it.
                let opener = trimmed.prefix { $0 == "`" }.count
                var end = index + 1
                while end < lines.count, !isClosingFence(lines[end], opener: opener) {
                    end += 1
                }
                // An unterminated fence is someone in the middle of typing one,
                // not a diagram. Nothing is drawn until they close it.
                if end < lines.count {
                    let source = lines[(index + 1)..<end].joined(separator: "\n")
                    let last = starts[end] + (lines[end] as NSString).length
                    if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let kind = fence.kind(source) {
                        found.append(Item(range: NSRange(location: starts[index],
                                                         length: last - starts[index]),
                                          kind: kind,
                                          alt: fence.rawValue))
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

    /// The fences that draw something, and what each one draws.
    enum Fence: String {
        case mermaid
        case form = "json"

        /// What this block turns into, or nil when it turns into nothing.
        ///
        /// A mermaid block is always a diagram — that is what the tag means.
        /// A JSON block is ordinary JSON until it is found to contain a
        /// `uiSchema`, which is the whole point: you paste a payload out of an
        /// IDP without tagging it anything special, and the form appears.
        func kind(_ source: String) -> Kind? {
            switch self {
            case .mermaid: return .diagram(source: source)
            case .form:
                // A scan before the parse: this runs over every fenced block on
                // every keystroke and a note can be mostly JSON, so anything
                // that cannot be a form should cost one pass over the string
                // rather than a parse.
                //
                // Both words, not just `uiSchema`: a block written by hand to
                // try a layout out *is* a uiSchema and never contains the word.
                // Gating on it alone silently dropped the one case this was
                // built for.
                guard source.contains("uiSchema") || source.contains("elements"),
                      UISchema.find(in: source) != nil else { return nil }
                return .form(source: source)
            }
        }
    }

    private static func isClosingFence(_ line: String, opener: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let ticks = trimmed.prefix { $0 == "`" }.count
        return ticks >= opener && trimmed.dropFirst(ticks).isEmpty
    }

    private static func drawableFence(_ trimmed: String) -> Fence? {
        let ticks = trimmed.prefix { $0 == "`" }.count
        guard ticks >= 3 else { return nil }
        switch trimmed.dropFirst(ticks).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "mermaid": return .mermaid
        // `jsonforms` and `uischema` for a block written by hand that is only a
        // uiSchema; `json` because that is what a pasted payload gets tagged,
        // and asking someone to retag it would be asking them to know about
        // this feature before they can find it.
        case "json", "jsonforms", "uischema": return .form
        default: return nil
        }
    }

    /// Where a note's pictures live: one folder beside the notes, so the whole
    /// thing is still something you can copy, sync or hand to somebody as a
    /// directory. Referenced from a note as `resources/img/…`.
    public static let folder = "resources/img"
}
