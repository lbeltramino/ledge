import Foundation

/// The headings in a note, for jumping around a long one.
///
/// A list you can open, not text written into the file. A materialised table of
/// contents — `[TOC]`, the `<!-- TOC -->` markers other editors keep up to
/// date — would be more text for two writers to disagree about, in the one
/// place where it took weeks to stop them doing exactly that.
public enum Headings {

    public struct Item: Equatable, Sendable {
        /// 1 for `#`, 2 for `##`, and so on.
        public let level: Int
        public let text: String
        /// The whole line, so a view can scroll to it.
        public let line: NSRange
    }

    /// `# Heading` is a heading, `#tag` is a tag: the space is what tells them
    /// apart, exactly as it does everywhere else in the app.
    static let pattern = "^(#{1,6})[ \\t]+([^\\n]+)$"

    private static let regex = try? NSRegularExpression(pattern: pattern,
                                                        options: [.anchorsMatchLines])

    public static func all(in text: String) -> [Item] {
        guard let regex else { return [] }
        let source = text as NSString
        let fenced = fencedRanges(in: source)

        return regex.matches(in: text, range: NSRange(location: 0, length: source.length))
            .compactMap { match in
                // A `# comment` inside a fenced block is a comment. Without
                // this, pasting a shell script fills the index with its own
                // remarks — and pasted code is a thing this app goes out of its
                // way to make easy.
                guard !fenced.contains(where: { NSIntersectionRange($0, match.range).length > 0 })
                else { return nil }

                let hashes = source.substring(with: match.range(at: 1))
                let body = source.substring(with: match.range(at: 2))
                    .trimmingCharacters(in: .whitespaces)
                guard !body.isEmpty else { return nil }
                return Item(level: hashes.count, text: body, line: match.range)
            }
    }

    /// Worth offering only when there is something to jump between.
    public static func worthShowing(in text: String) -> Bool { all(in: text).count >= 2 }

    private static let fenceRegex = try? NSRegularExpression(
        pattern: "^(```|~~~)[^\n]*\n[\\s\\S]*?^\\1[ \t]*$",
        options: [.anchorsMatchLines])

    private static func fencedRanges(in text: NSString) -> [NSRange] {
        guard let fenceRegex else { return [] }
        return fenceRegex.matches(in: text as String,
                                  range: NSRange(location: 0, length: text.length))
            .map(\.range)
    }
}
