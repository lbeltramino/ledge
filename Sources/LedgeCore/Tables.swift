import Foundation

/// Markdown tables: where they are, and what is in them.
///
/// Only the parsing lives here — no measuring, no drawing, no idea that a
/// screen exists. That is what makes a table something the checks can reason
/// about without one.
public enum Tables {

    public enum Alignment: Equatable, Sendable { case left, centre, right }

    public struct Table: Equatable, Sendable {
        /// Every line of it, header and rule included, so it can be hidden and
        /// drawn over — or handed back as the text that defines it.
        public let range: NSRange
        public let header: [String]
        public let rows: [[String]]
        public let alignment: [Alignment]

        public var columns: Int { header.count }
    }

    /// A row is a line with at least one unescaped pipe; the rule under the
    /// header is what makes the block a table rather than prose with pipes in
    /// it — which is exactly how GitHub decides, and how a line of shell with a
    /// pipe in it stays a line of shell.
    private static let rulePattern = "^[ \t]*\\|?[ \t]*:?-{1,}:?[ \t]*(\\|[ \t]*:?-{1,}:?[ \t]*)+\\|?[ \t]*$"
    private static let ruleRegex = try? NSRegularExpression(pattern: rulePattern)

    public static func all(in text: String) -> [Table] {
        let source = text as NSString
        let lines = text.components(separatedBy: "\n")
        var starts: [Int] = []
        var offset = 0
        for line in lines {
            starts.append(offset)
            offset += (line as NSString).length + 1
        }

        var found: [Table] = []
        var index = 0
        while index < lines.count {
            // A header, a rule under it, and at least one row.
            guard index + 1 < lines.count,
                  isRow(lines[index]),
                  isRule(lines[index + 1]) else {
                index += 1
                continue
            }
            let header = cells(of: lines[index])
            let alignment = alignments(of: lines[index + 1], columns: header.count)

            var rows: [[String]] = []
            var last = index + 1
            var cursor = index + 2
            while cursor < lines.count, isRow(lines[cursor]) {
                rows.append(padded(cells(of: lines[cursor]), to: header.count))
                last = cursor
                cursor += 1
            }
            guard !rows.isEmpty else { index += 1; continue }

            let start = starts[index]
            let end = starts[last] + (lines[last] as NSString).length
            found.append(Table(range: NSRange(location: start, length: end - start),
                               header: header, rows: rows, alignment: alignment))
            index = cursor
        }
        _ = source
        return found
    }

    /// The table containing `location`, if any — what a click has to resolve.
    public static func containing(_ location: Int, in text: String) -> Table? {
        all(in: text).first { NSLocationInRange(location, $0.range) || location == $0.range.upperBound }
    }

    static func isRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return false }
        // A fenced line or a list item that merely mentions a pipe is not a row.
        return !trimmed.hasPrefix("```") && !trimmed.hasPrefix("~~~")
    }

    static func isRule(_ line: String) -> Bool {
        guard let ruleRegex else { return false }
        let source = line as NSString
        return ruleRegex.firstMatch(in: line, range: NSRange(location: 0, length: source.length)) != nil
    }

    /// The cells of a row, with the outer pipes dropped and `\|` respected.
    static func cells(of line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") { trimmed.removeLast() }

        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in trimmed {
            if escaped {
                current.append(character == "|" ? "|" : character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    static func alignments(of rule: String, columns: Int) -> [Alignment] {
        let marks = cells(of: rule).map { cell -> Alignment in
            let left = cell.hasPrefix(":")
            let right = cell.hasSuffix(":")
            if left && right { return .centre }
            if right { return .right }
            return .left
        }
        return padded(marks, to: columns, with: .left)
    }

    private static func padded(_ cells: [String], to count: Int) -> [String] {
        padded(cells, to: count, with: "")
    }

    private static func padded<T>(_ values: [T], to count: Int, with filler: T) -> [T] {
        if values.count >= count { return Array(values.prefix(count)) }
        return values + Array(repeating: filler, count: count - values.count)
    }
}
