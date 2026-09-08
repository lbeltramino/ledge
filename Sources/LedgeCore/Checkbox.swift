import Foundation

/// `- [ ]` and `- [x]`.
///
/// A sticky note is a to-do list most of the time, so the list markers Ledge
/// already understood were only ever half the job.
public enum Checkbox {

    public struct Item: Equatable, Sendable {
        /// The whole line.
        public let line: NSRange
        /// Just the `[ ]`, which is what you click.
        public let box: NSRange
        /// The text after the box.
        public let content: NSRange
        public let isDone: Bool
    }

    /// `[^\n]*` rather than `.*` on purpose: the markdown highlighter compiles
    /// its patterns with `dotMatchesLineSeparators`, and a `.` there swallows
    /// every line below — the same pattern behaving differently in two places.
    public static let pattern = "^([ \\t]*)([-*+])[ \\t]+\\[([ xX])\\][ \\t]*([^\\n]*)$"

    private static let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])

    public static func items(in text: String) -> [Item] {
        guard let regex else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length))
            .map { match in
                let mark = source.substring(with: match.range(at: 3))
                // the box including its brackets
                let box = NSRange(location: match.range(at: 3).location - 1,
                                  length: match.range(at: 3).length + 2)
                return Item(line: match.range, box: box, content: match.range(at: 4),
                            isDone: mark.lowercased() == "x")
            }
    }

    /// The item containing `index`, if the click landed on a line that has one.
    public static func item(in text: String, at index: Int) -> Item? {
        items(in: text).first { NSLocationInRange(index, $0.line) || index == $0.line.upperBound }
    }

    /// Flips the box on the line containing `index`.
    ///
    /// Returns the range of the single character that changed, so a text view
    /// can replace it without disturbing the caret or the undo stack more than
    /// it must.
    public static func toggle(in text: String, at index: Int) -> (range: NSRange, replacement: String)? {
        guard let item = item(in: text, at: index) else { return nil }
        let markLocation = item.box.location + 1
        return (NSRange(location: markLocation, length: 1), item.isDone ? " " : "x")
    }

    /// The marker to continue a checklist with, given the line above.
    public static func continuation(after line: String) -> String? {
        guard let regex else { return nil }
        let source = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: source.length))
        else { return nil }
        let indent = source.substring(with: match.range(at: 1))
        let bullet = source.substring(with: match.range(at: 2))
        // an empty item means the list is finished
        let content = source.substring(with: match.range(at: 4)).trimmingCharacters(in: .whitespaces)
        return content.isEmpty ? "" : "\(indent)\(bullet) [ ] "
    }

    /// How many are done, out of how many — for a note's summary line.
    public static func progress(in text: String) -> (done: Int, total: Int)? {
        let all = items(in: text)
        guard !all.isEmpty else { return nil }
        return (all.filter(\.isDone).count, all.count)
    }
}
