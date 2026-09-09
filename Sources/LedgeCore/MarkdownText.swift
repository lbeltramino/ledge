import Foundation

/// The text transformations behind the editing keys.
///
/// Pure string in, pure string out, so every one of them can be tested without
/// a window — which is the only reason to trust that Tab does the right thing
/// to a list you cannot see.
public enum MarkdownText {

    /// Two spaces per level: what most Markdown writers use, and narrow enough
    /// to nest twice in a note 300 points wide.
    public static let indentWidth = 2

    /// The shape of a list line, whatever kind it is.
    public struct Marker: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case bullet(String)     // -, * or +
            case ordered(Int)       // 1.
            case quote
        }
        public let indent: Int
        public let kind: Kind
        /// Length of everything before the content: indent, marker, checkbox.
        public let prefixLength: Int
        public let isTask: Bool
        public let isDone: Bool
        public let contentIsEmpty: Bool
    }

    private static let listRegex = try? NSRegularExpression(
        pattern: "^([ \\t]*)(?:([-*+])|(\\d+)\\.)[ \\t]+(\\[([ xX])\\][ \\t]*)?(.*)$",
        options: [.anchorsMatchLines])
    private static let quoteRegex = try? NSRegularExpression(
        pattern: "^([ \\t]*)(>)[ \\t]?(.*)$", options: [.anchorsMatchLines])

    public static func marker(of line: String) -> Marker? {
        let source = line as NSString
        let whole = NSRange(location: 0, length: source.length)

        if let match = listRegex?.firstMatch(in: line, range: whole) {
            let indent = source.substring(with: match.range(at: 1))
            let task = match.range(at: 4)
            let kind: Marker.Kind
            if match.range(at: 2).location != NSNotFound {
                kind = .bullet(source.substring(with: match.range(at: 2)))
            } else {
                kind = .ordered(Int(source.substring(with: match.range(at: 3))) ?? 1)
            }
            let done = match.range(at: 5).location != NSNotFound
                && source.substring(with: match.range(at: 5)).lowercased() == "x"
            let content = source.substring(with: match.range(at: 6))
            return Marker(indent: width(of: indent), kind: kind,
                          prefixLength: match.range(at: 6).location,
                          isTask: task.location != NSNotFound, isDone: done,
                          contentIsEmpty: content.trimmingCharacters(in: .whitespaces).isEmpty)
        }

        if let match = quoteRegex?.firstMatch(in: line, range: whole) {
            let indent = source.substring(with: match.range(at: 1))
            let content = source.substring(with: match.range(at: 3))
            return Marker(indent: width(of: indent), kind: .quote,
                          prefixLength: match.range(at: 3).location,
                          isTask: false, isDone: false,
                          contentIsEmpty: content.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        return nil
    }

    /// A tab counts as a full level; anything else counts as itself.
    static func width(of indent: String) -> Int {
        indent.reduce(0) { $0 + ($1 == "\t" ? indentWidth : 1) }
    }

    // MARK: - Tab and Shift-Tab

    /// Indents or outdents every list line the range touches.
    ///
    /// Returns nil when none of them is a list line, so Tab can fall through to
    /// inserting a tab the way it does everywhere else.
    public static func shiftIndent(_ text: String, lines: NSRange, by levels: Int) -> String? {
        let source = text as NSString
        // Clamped rather than trusted: a range that runs past the end throws,
        // and a text transformation should return nil, not take the app with it.
        let start = max(0, min(lines.location, source.length))
        let lines = NSRange(location: start, length: max(0, min(lines.length, source.length - start)))
        let block = source.substring(with: lines)
        let rows = block.components(separatedBy: "\n")
        guard rows.contains(where: { marker(of: $0) != nil }) else { return nil }

        let shifted = rows.map { row -> String in
            guard let found = marker(of: row) else { return row }
            let target = max(0, found.indent + levels * indentWidth)
            let body = String(row.drop(while: { $0 == " " || $0 == "\t" }))
            return String(repeating: " ", count: target) + body
        }.joined(separator: "\n")

        return source.replacingCharacters(in: lines, with: renumber(shifted))
    }

    // MARK: - numbering

    /// Renumbers ordered lists so each level counts from one, again.
    ///
    /// Without this, indenting the third item of a list leaves a nested list
    /// starting at three, and inserting in the middle leaves two items called 2.
    public static func renumber(_ text: String) -> String {
        var counters: [Int: Int] = [:]
        var lastIndent = -1

        let rows = text.components(separatedBy: "\n").map { row -> String in
            guard let found = marker(of: row) else {
                if row.trimmingCharacters(in: .whitespaces).isEmpty == false { counters.removeAll() }
                return row
            }
            // stepping back out abandons the deeper counters
            if found.indent < lastIndent {
                // The keys have to be taken first: mutating a dictionary while
                // iterating its own key view traps.
                for level in Array(counters.keys) where level > found.indent {
                    counters[level] = nil
                }
            }
            lastIndent = found.indent

            guard case .ordered = found.kind else {
                counters[found.indent] = nil
                return row
            }
            let next = (counters[found.indent] ?? 0) + 1
            counters[found.indent] = next

            let source = row as NSString
            guard let match = listRegex?.firstMatch(in: row,
                                                    range: NSRange(location: 0, length: source.length)),
                  match.range(at: 3).location != NSNotFound else { return row }
            return source.replacingCharacters(in: match.range(at: 3), with: String(next))
        }
        return rows.joined(separator: "\n")
    }

    // MARK: - moving lines

    /// Moves the lines a selection touches up or down by one.
    ///
    /// Returns the new text and where the selection ends up, so the lines you
    /// moved stay selected and you can keep pressing.
    public static func moveLines(_ text: String, lines: NSRange,
                                 by direction: Int) -> (text: String, selection: NSRange)? {
        let source = text as NSString
        var rows = text.components(separatedBy: "\n")
        guard rows.count > 1 else { return nil }

        // which rows the range covers
        var starts: [Int] = []
        var offset = 0
        for row in rows {
            starts.append(offset)
            offset += (row as NSString).length + 1
        }
        let first = starts.lastIndex { $0 <= lines.location } ?? 0
        let last = starts.lastIndex { $0 < max(lines.upperBound, lines.location + 1) } ?? first

        let target = direction < 0 ? first - 1 : last + 1
        guard target >= 0, target < rows.count else { return nil }

        let block = Array(rows[first...last])
        rows.removeSubrange(first...last)
        let insertAt = direction < 0 ? first - 1 : first + 1
        rows.insert(contentsOf: block, at: insertAt)

        let joined = rows.joined(separator: "\n")
        // where the moved block now begins
        var newStart = 0
        for row in rows.prefix(insertAt) { newStart += (row as NSString).length + 1 }
        let length = block.map { ($0 as NSString).length + 1 }.reduce(0, +) - 1
        _ = source
        return (renumber(joined), NSRange(location: newStart, length: max(0, length)))
    }

    // MARK: - pasting

    /// Whether a pasted string is a link, in which case pasting it over some
    /// selected words should make them the link's text rather than replace them.
    public static func isLink(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return false }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto", "ftp", "ledge"].contains(scheme) && url.host != nil
            || scheme == "mailto"
    }

    /// The pairs that wrap a selection when you type the opening one.
    public static let wrappingPairs: [Character: String] = [
        "(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`", "*": "*", "_": "_",
    ]

    // MARK: - backspace

    /// Backspace at the very start of a list item's text takes the marker off
    /// rather than eating into the line above.
    public static func outdentOrUnmark(_ text: String, at caret: Int) -> (range: NSRange, replacement: String)? {
        let source = text as NSString
        let lineRange = source.lineRange(for: NSRange(location: caret, length: 0))
        let line = source.substring(with: lineRange).trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
        guard let found = marker(of: line) else { return nil }
        guard caret == lineRange.location + found.prefixLength else { return nil }

        if found.indent > 0 {
            let target = max(0, found.indent - indentWidth)
            let body = String(line.drop(while: { $0 == " " || $0 == "\t" }))
            return (NSRange(location: lineRange.location, length: (line as NSString).length),
                    String(repeating: " ", count: target) + body)
        }
        // no indent left to give up: drop the marker itself
        return (NSRange(location: lineRange.location, length: found.prefixLength), "")
    }
}
